module Analytics
  module Report
    # One method per report (Analytics::Report::KEYS), each returning a Table. The funnels, stuck-at and cohort tables come from ParticipantFunnel (the
    # `insights` views, one definition of each step); the rest is plain grouped SQL over the live tables. Every query leaves out staff, simulated players
    # and listed testers through Analytics::Exclusion.included_sql (the MEASURED token, filled in after the binds), reads no person column and
    # returns counts only.
    class Sections
      MEASURED = AdminMetrics::MEASURED
      DAY_SECONDS = 24 * 3600
      TABLES = %w[analytics_visits analytics_events analytics_site_days analytics_daily_snapshots job_runs].freeze

      VISIT_STEP_LABELS = {
        visited: "Saw the landing page or onboarding", age: "Onboarding, age step", prize: "Onboarding, prize step", project: "Onboarding, project step",
        schedule: "Onboarding, schedule step", signup: "Onboarding, sign-up step", signup_started: "Pressed sign up", signed_up: "Signed up"
      }.freeze
      INELIGIBLE_LABEL = "Left: not a teen (answered the age question)".freeze
      BREAKDOWNS = { referral_slug: "Referral link", referrer_kind: "Came from", device_class: "Device", utm_source: "UTM source" }.freeze
      STAGE_LABELS = { completed: "Completed every step" }.freeze

      STATUS_TEXT = {
        "ok" => "Ran fine", "failed" => "Last run failed", "running" => "Running now", "stale" => "Stale", "never_run" => "Never run",
        "off" => "Switched off by its flag", "unscheduled" => "Not in the schedule"
      }.freeze

      def initialize(window)
        @window = window
        @now = Time.current.utc
      end

      # The visitor funnel before sign-up, over visits (browser sessions), from ParticipantFunnel.visits: each step counts the visits that reached it
      # on its own, so a step can be higher than the one before it (a person who came back mid-flow).
      def visits
        counts = ParticipantFunnel.visits(since: @window.first_day, until: until_date)
        steps = VISIT_STEP_LABELS.map { |key, label| [ key.to_s, label, counts.fetch(key) ] }
        rows = funnel_rows(steps, lost: false)
        rows << { key: "ineligible", step: INELIGIBLE_LABEL, count: counts.fetch(:ineligible) }
        table(:visits, "Visitor funnel (visits)", "Browser sessions, not people: one person on two devices is two visits until they sign in. Visits started in the " \
                                                  "#{@window.label}; people who send Do Not Track or Global Privacy Control are not in it. Only events collected since launch exist.",
              funnel_columns("Visits", lost: false), rows)
      rescue ActiveRecord::StatementInvalid => error
        insights_missing(:visits, "Visitor funnel (visits)", error)
      end

      # The participant funnel (after sign-up): people who signed up in the period, nested (each step only people who passed every earlier step) with the
      # step on its own beside it and the median time from the nearest earlier step. A cell under 5 is "<5" for a period; all time is never hidden.
      def funnel
        result = ParticipantFunnel.run(since: @window.first_day, until: until_date)
        ever = result.fetch(:ever_reached).index_by { |step| step[:key].to_s }
        rows = funnel_rows(result.fetch(:nested).map { |step| [ step[:key].to_s, step[:label], step[:count] ] }, lost: true)
        rows.each { |row| row.merge!(ever_columns(ever.fetch(row[:key]))) }
        nested_keys = rows.map { |row| row[:key] }
        result.fetch(:ever_reached).reject { |step| nested_keys.include?(step[:key].to_s) }.each do |step|
          rows << { key: step[:key].to_s, step: step[:label] }.merge(ever_columns(step))
        end
        columns = funnel_columns("People", lost: true, reached: "Ever reached (not nested)") +
                  [ Column.new(key: :median_hours_from_earlier_step, label: "Median hours from the step before", kind: :hours), count(:timed, "People timed") ]
        table(:funnel, "Participant funnel (people)", "People who signed up in the #{@window.label}. Each step counts a person only if they passed every earlier step; " \
                                                      "\"Ever reached\" counts each step on its own, with the median time from the nearest earlier step. Steps are the ParticipantFunnel definitions.",
              columns, rows)
      rescue ActiveRecord::StatementInvalid => error
        insights_missing(:funnel, "Participant funnel (people)", error)
      end

      # People per funnel stage (the first step they have not done) and how long they have been there.
      def stuck
        rows = ParticipantFunnel.stuck.map do |row|
          { stage: STAGE_LABELS.fetch(row[:stage]) { ParticipantFunnel::STEPS.find { |step| step.key == row[:stage] }&.label || row[:stage].to_s.humanize }, people: row[:people], median_days: row[:median_days] }
        end
        columns = [ text(:stage, "Stuck before"), count(:people, "People"), Column.new(key: :median_days, label: "Median days there", kind: :hours) ]
        table(:stuck, "Stuck at", "Everyone who signed up, by the first step they have not done yet (all time). A group under 5 is \"<5\".", columns, rows)
      rescue ActiveRecord::StatementInvalid => error
        insights_missing(:stuck, "Stuck at", error)
      end

      # Sign-up weeks (Friday to Thursday) with how many came back the day after and a week after.
      def cohorts
        rows = ParticipantFunnel.cohorts(since: @window.first_day, until: until_date).map do |week|
          { week_starting: week[:week_starts_on].iso8601, people: week[:people],
            day1_eligible: week[:day1][:eligible], day1_returned: week[:day1][:returned], day1_percent: week[:day1][:percent],
            day7_eligible: week[:day7][:eligible], day7_returned: week[:day7][:returned], day7_percent: week[:day7][:percent] }
        end
        columns = [ text(:week_starting, "Sign-up week from (Friday)"), count(:people, "Signed up"), count(:day1_eligible, "Day 1 passed"), count(:day1_returned, "Came back on day 1"),
                    Column.new(key: :day1_percent, label: "Day 1 %", kind: :percent), count(:day7_eligible, "Day 7 passed"), count(:day7_returned, "Came back on day 7"),
                    Column.new(key: :day7_percent, label: "Day 7 %", kind: :percent) ]
        table(:cohorts, "Sign-up cohorts", "Came back means a signed-in visit or counted coding on that day after signing up. Only people whose day has passed are counted; " \
                                           "a count under 5 is \"<5\".", columns, rows)
      rescue ActiveRecord::StatementInvalid => error
        insights_missing(:cohorts, "Sign-up cohorts", error)
      end

      # One row per UTC day, newest first. Counts are people or things per day; "active players" are players with at least the streak
      # threshold of coded time on their own local date (the rule of /admin/metrics).
      def daily
        since = @window.since
        first_day = @window.first_day || first_data_day
        days = (first_day..@window.today).to_a.reverse
        measured = { visits: visits_per_day(since), signups: signups_per_day(since), site_people: site_people_per_day, coded: coded_per_day,
                     submitted: ships_per_day("submitted_at", "ships.submitted_at IS NOT NULL"), approved: ships_per_day("reviewed_at", "ships.status = 'approved'"),
                     purchases: purchases_per_day, damage: boss_damage_per_day }
        rows = days.map do |day|
          coded = measured[:coded][day] || [ 0, 0 ]
          { day: day.iso8601, visits: measured[:visits][day].to_i, signups: measured[:signups][day].to_i, site_people: measured[:site_people][day].to_i,
            active_players: coded.first.to_i, hours_coded: hours(coded.last), ships_submitted: measured[:submitted][day].to_i,
            ships_approved: measured[:approved][day].to_i, purchases: measured[:purchases][day].to_i, boss_damage_hours: hours(measured[:damage][day]) }
        end
        columns = [ text("day", "Day (UTC)"), count("visits", "Visits"), count("signups", "Sign-ups"), count("site_people", "Signed-in people who visited"),
                    count("active_players", "Active players (15+ min coded)"), hours_column("hours_coded", "Hours coded"),
                    count("ships_submitted", "Ships submitted"), count("ships_approved", "Ships approved"), count("purchases", "Purchases"),
                    hours_column("boss_damage_hours", "Boss damage (hours of submitted ships)") ]
        table(:daily, "Per day", "Days are UTC dates, except active players and hours coded, which use each player's own local date. Purchases are shop purchases " \
                                 "that were not cancelled (the free sticker is not one). Boss damage is the coded hours of ships submitted that day, as the boss counts it.",
              columns, rows)
      end

      # Visits by referral link, where they came from, device and UTM source (ParticipantFunnel.visits_by): how many saw the landing page or onboarding and how
      # many of those visits signed up. A count under 5 is "<5", and the percentage is hidden with it.
      def referrals
        rows = BREAKDOWNS.flat_map do |dimension, label|
          ParticipantFunnel.visits_by(dimension, since: @window.first_day, until: until_date).map do |row|
            hidden = [ row[:visited], row[:signed_up] ].include?(ParticipantFunnel::SUPPRESSED)
            { breakdown: label, value: row[:value], visits: row[:visited], signed_up_visits: row[:signed_up],
              conversion_percent: hidden ? nil : Report.percent(row[:signed_up], row[:visited]) }
          end
        end
        columns = [ text(:breakdown, "Breakdown"), text(:value, "Value"), count(:visits, "Visits that saw the landing page or onboarding"),
                    count(:signed_up_visits, "Visits that signed up"), Column.new(key: :conversion_percent, label: "Signed up %", kind: :percent) ]
        table(:referrals, "Where visits come from", "First-touch, per visit started in the #{@window.label}. The path link (/haven, /stardance, ...) is the main channel; " \
                                                    "UTM values outside the allowlist are stored as \"other\". A cell under 5 is shown as \"<5\".", columns, rows)
      rescue ActiveRecord::StatementInvalid => error
        insights_missing(:referrals, "Where visits come from", error)
      end

      # Every allowlisted event with how many were recorded in the period, in the last 24 hours and when the last one came: an event that stays
      # at zero after launch is a hook that is not firing.
      def events
        found = run(<<~SQL, since: @window.since, day_ago: @now - DAY_SECONDS).to_h { |row| [ row["name"], row ] }
          SELECT e.name, COUNT(*) AS in_range, COUNT(*) FILTER (WHERE e.occurred_at >= :day_ago) AS last_day, MAX(e.occurred_at) AS last_at
          FROM analytics_events e
          LEFT JOIN users ON users.id = e.user_id
          WHERE e.occurred_at >= :since AND (users.id IS NULL OR #{MEASURED})
          GROUP BY e.name
        SQL
        rows = Analytics::Events.names.sort.map do |name|
          row = found[name]
          { event: name, in_range: Report.suppress(row&.fetch("in_range")), last_24_hours: Report.suppress(row&.fetch("last_day")),
            last_seen: row && row["last_at"].to_time.utc.iso8601, wired: row ? "recorded" : "none yet" }
        end
        columns = [ text("event", "Event"), count("in_range", "In the period"), count("last_24_hours", "Last 24 hours"),
                    Column.new(key: "last_seen", label: "Last seen (UTC)", kind: :time), text("wired", "Status") ]
        table(:events, "Events by name", "All #{rows.size} events of the allowlist (config/analytics.yml), recorded in the #{@window.label}. \"none yet\" means no row: " \
                                         "either nothing happened or the hook is not firing. Counts of one to four are shown as \"<5\".", columns, rows)
      end

      # Last run of every scheduled job (JobSchedule over job_runs), red and in words when it has not succeeded for twice its interval.
      def jobs
        entries = JobSchedule.status(now: @now)
        rows = entries.map { |entry| job_row(entry) } + unscheduled_jobs(entries.map(&:name))
        columns = [ text(:job, "Job"), Column.new(key: :status, label: "State", kind: :status), text(:detail, "In words"),
                    Column.new(key: :last_run, label: "Last run (UTC)", kind: :time), Column.new(key: :last_success, label: "Last success (UTC)", kind: :time),
                    count(:expected_every_minutes, "Expected every (minutes)"), text(:last_error, "Last error class") ]
        table(:jobs, "Scheduled jobs", "From job_runs and config/job_schedule.yml. A job is stale when it has had no successful run for twice its interval. " \
                                       "A job that has never run may not be scheduled in cron yet.", columns, rows)
      end

      # Size and row count of every analytics table, so growth is visible (nothing is ever pruned).
      def tables
        sizes = run(<<~SQL, names: TABLES).to_h { |row| [ row["relname"], row ] }
          SELECT c.relname, c.reltuples::bigint AS estimate, pg_total_relation_size(c.oid) AS total, pg_table_size(c.oid) AS heap, pg_indexes_size(c.oid) AS indexes
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = current_schema() AND c.relkind = 'r' AND c.relname IN (:names)
        SQL
        recent = { "analytics_visits" => "started_at >= :ago", "analytics_events" => "occurred_at >= :ago", "analytics_site_days" => "day >= :day",
                   "analytics_daily_snapshots" => "day >= :day", "job_runs" => "started_at >= :ago" }
        rows = TABLES.map do |name|
          size = sizes.fetch(name)
          # A table that has never been analysed reports -1, and a small one is cheap to count: both get the exact count.
          estimate = size["estimate"].to_i
          rows_now = estimate < 10_000 ? run("SELECT COUNT(*) AS n FROM #{name}").first["n"].to_i : estimate
          added = run("SELECT COUNT(*) AS n FROM #{name} WHERE #{recent.fetch(name)}", ago: @now - DAY_SECONDS, day: @window.today - 1).first["n"].to_i
          { table: name, rows: rows_now, new_rows_24_hours: added, table_bytes: size["heap"].to_i, index_bytes: size["indexes"].to_i, total_bytes: size["total"].to_i }
        end
        columns = [ text("table", "Table"), count("rows", "Rows"), count("new_rows_24_hours", "New rows, last 24 hours"), bytes("table_bytes", "Table size"),
                    bytes("index_bytes", "Index size"), bytes("total_bytes", "Total size") ]
        table(:tables, "Table sizes and growth", "Nothing in these tables is ever deleted on a schedule, so this is how they grow. Rows are the exact count up to 10,000 and " \
                                                 "the database's estimate above that; sizes include indexes. Site days and snapshots count new days (today and yesterday).",
              columns, rows)
      end

      private

      def table(key, title, description, columns, rows, note = nil)
        Table.new(key: key.to_s, title: title, description: description, columns: columns, rows: rows, note: note)
      end

      def insights_missing(key, title, error)
        Rails.logger.error("Analytics::Report #{key}: #{error.class}")
        table(key, title, "", [ text(:step, "Step") ], [], "Could not be computed: the insights views are not loaded (rake insights:rebuild).")
      end

      def text(key, label) = Column.new(key: key, label: label, kind: :text)
      def count(key, label) = Column.new(key: key, label: label, kind: :count)
      def bytes(key, label) = Column.new(key: key, label: label, kind: :bytes)
      def hours_column(key, label) = Column.new(key: key, label: label, kind: :hours)

      def hours(seconds) = (seconds.to_i / 3600.0).round(1)

      def ever_columns(step)
        { reached: step[:count], median_hours_from_earlier_step: step[:median_seconds] && (step[:median_seconds] / 3600.0).round(1), timed: step[:timed] }
      end

      # The window's last day when it is a period; all time has no bounds at all (and so no hidden cells).
      def until_date = @window.first_day && @window.today

      def funnel_columns(unit, lost:, reached: nil)
        [ text(:step, "Step"), count(:count, unit), Column.new(key: :percent_of_previous, label: "% of the step before", kind: :percent),
          Column.new(key: :percent_of_first, label: "% of the first step", kind: :percent),
          (count(:lost, "Lost since the step before") if lost), (count(:reached, reached) if reached) ].compact
      end

      # steps: [key, label, count]. Conversion is worked out here from the counts; a count hidden as "<5" has no percentage.
      def funnel_rows(steps, lost:)
        first = steps.first[2]
        steps.each_with_index.map do |(key, label, count), index|
          previous = index.positive? ? steps[index - 1][2] : nil
          { key: key, step: label, count: count, percent_of_previous: previous && Report.percent(count, previous), percent_of_first: Report.percent(count, first),
            lost: (previous.is_a?(Integer) && count.is_a?(Integer) ? [ previous - count, 0 ].max : nil if lost) }
        end
      end

      def measured_visits
        "FROM analytics_visits v LEFT JOIN users ON users.id = v.user_id WHERE v.started_at >= :since AND (users.id IS NULL OR #{MEASURED})"
      end

      def visits_per_day(since) = per_day("SELECT v.started_at::date AS day, COUNT(*) AS n #{measured_visits} GROUP BY 1", since: since)

      def signups_per_day(since) = per_day("SELECT created_at::date AS day, COUNT(*) AS n FROM users WHERE created_at >= :since AND #{MEASURED} GROUP BY 1", since: since)

      def site_people_per_day
        per_day("SELECT sd.day AS day, COUNT(*) AS n FROM analytics_site_days sd JOIN users ON users.id = sd.user_id " \
                "WHERE sd.day >= :first AND #{MEASURED} GROUP BY 1", first: @window.first_day || Date.new(2000, 1, 1))
      end

      # Day => [players with the threshold, seconds coded], from the same counted ledger rows as /admin/metrics.
      def coded_per_day
        rows = run(<<~SQL, days_before: Hours::Config.current.days_before_signup_counted, minimum: Game::Config.current.quick_seconds, first: @window.first_day || Date.new(2000, 1, 1))
          SELECT local_date AS day, COUNT(*) FILTER (WHERE seconds >= :minimum) AS players, SUM(GREATEST(seconds, 0)) AS seconds
          FROM (
            SELECT user_id, local_date, SUM(seconds) AS seconds FROM #{AdminMetrics::COUNTED_ENTRIES} WHERE local_date >= :first GROUP BY user_id, local_date
          ) per_player GROUP BY local_date
        SQL
        rows.to_h { |row| [ row["day"].to_date, [ row["players"].to_i, row["seconds"].to_i ] ] }
      end

      def ships_per_day(time_column, condition)
        per_day("SELECT ships.#{time_column}::date AS day, COUNT(*) AS n FROM ships JOIN users ON users.id = ships.user_id " \
                "WHERE ships.#{time_column} >= :since AND #{condition} AND #{MEASURED} GROUP BY 1", since: @window.since)
      end

      def purchases_per_day
        per_day("SELECT orders.created_at::date AS day, COUNT(*) AS n FROM orders JOIN users ON users.id = orders.user_id " \
                "WHERE orders.created_at >= :since AND orders.kind = 'purchase' AND orders.status <> 'cancelled' AND #{MEASURED} GROUP BY 1", since: @window.since)
      end

      def boss_damage_per_day
        per_day("SELECT ships.submitted_at::date AS day, SUM(#{Bosses::Damage::SECONDS}) AS n FROM ships JOIN users ON users.id = ships.user_id " \
                "WHERE ships.submitted_at >= :since AND ships.status IN (:statuses) AND #{MEASURED} GROUP BY 1", since: @window.since, statuses: Ship::WINDOW_STATUSES)
      end

      def first_data_day
        [ User.minimum(:created_at), AnalyticsVisit.minimum(:started_at), Ship.minimum(:submitted_at), Order.minimum(:created_at) ].compact.min&.utc&.to_date || @window.today
      end

      def per_day(sql, **binds) = run(sql, **binds).to_h { |row| [ row["day"].to_date, row["n"].to_i ] }

      # Named binds go in first; the measured-people condition is added afterwards, so a uid containing a colon or a quote is never read as a bind.
      def run(sql, **binds)
        sql = User.sanitize_sql_array([ sql, binds ]) if binds.any?
        User.connection.select_all(sql.gsub(MEASURED, Analytics::Exclusion.included_sql("users"))).to_a
      end

      def job_row(entry)
        status = entry.state == :ok && entry.last_status == "failed" ? "failed" : entry.state.to_s
        detail = STATUS_TEXT.fetch(status)
        if status == "stale"
          since = entry.last_success_at ? "no successful run for #{ActionController::Base.helpers.distance_of_time_in_words(entry.last_success_at, @now)}" : "it has never succeeded"
          detail += ": #{since} (expected every #{entry.interval_minutes} minutes)"
        end
        { job: entry.name, status: status, detail: detail, last_run: entry.last_run_at&.utc&.iso8601, last_success: entry.last_success_at&.utc&.iso8601,
          expected_every_minutes: entry.interval_minutes, last_error: entry.last_error_class }
      end

      # Jobs that have run but are not in config/job_schedule.yml: listed, never called stale.
      def unscheduled_jobs(scheduled)
        JobRun.where.not(name: scheduled).select("DISTINCT ON (name) name, started_at, finished_at, status, error_class").order(:name, started_at: :desc).map do |last|
          { job: last.name, status: "unscheduled", detail: STATUS_TEXT.fetch("unscheduled"), last_run: last.started_at.utc.iso8601,
            last_success: (last.finished_at.utc.iso8601 if last.status == "ok" && last.finished_at), expected_every_minutes: nil, last_error: last.error_class }
        end
      end
    end
  end
end
