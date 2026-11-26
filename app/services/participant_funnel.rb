# The participant funnel, read from the `insights` views (db/insights/views.sql.erb, plans/analytics.md sections 3 and 4). It returns plain hashes of
# numbers: no person id, name or email ever leaves it. Everything after sign-up is derived from the product tables, so it works for people who signed
# up before any event existed; only the pre-sign-up funnel (Visits) needs events. Staff, simulated players and listed testers are not in the views.
#
#   ParticipantFunnel.run                               # { total:, nested: [...], ever_reached: [...] }
#   ParticipantFunnel.run(since: Date.new(2026, 11, 27), until: Date.new(2026, 12, 3), cohort: "haven")
#   ParticipantFunnel.visits(since:, until:)            # the visitor funnel over browser sessions (before sign-up)
#   ParticipantFunnel.visits_by(:referral_slug)         # the same, one row per value, small cells hidden
#   ParticipantFunnel.cohorts                           # sign-up weeks with day-1 and day-7 return
#   ParticipantFunnel.stuck                             # people per funnel_stage and for how long
#   ParticipantFunnel::Stage.for(user)                  # one person's stage and "stuck since"
#
# A breakdown cell under MIN_CELL people is returned as SUPPRESSED ("<5"), never the number, so a small group cannot point at anyone. That applies
# whenever the result is a part of the population (a date window, a cohort, a breakdown); the unfiltered totals are never suppressed.
class ParticipantFunnel
  Step = Data.define(:key, :label, :column, :date)

  # In funnel order. `column` is a column of insights.funnel_facts; a `date` step holds a local DATE (first_active_on ...), the others a timestamp.
  STEPS = [
    Step.new(:signed_up, "Signed up", "signed_up_at", false),
    Step.new(:onboarded, "Onboarded", "onboarded_at", false),
    Step.new(:linked_hackatime, "Linked Hackatime", "linked_hackatime_at", false),
    Step.new(:added_project, "Added a project with Hackatime", "added_project_at", false),
    Step.new(:first_active_day, "First active day", "first_active_on", true),
    Step.new(:past_5h, "Past 5 hours", "past_5h_on", true),
    Step.new(:shipped, "Shipped", "shipped_at", false),
    Step.new(:approved, "First ship approved", "approved_at", false),
    Step.new(:bought, "Bought something", "bought_at", false)
  ].freeze

  # Hour milestones; 5 is a step above, 1 and 10 are extra "ever reached" rows (insights_private.hour_milestones has the three columns).
  HOUR_MARKS = [ 1, 5, 10 ].freeze

  # `ever_reached` rows: every step on its own, plus the other hour marks next to past_5h.
  EVER_STEPS = STEPS.flat_map do |step|
    case step.key
    when :past_5h then [ Step.new(:past_1h, "Past 1 hour", "past_1h_on", true), step, Step.new(:past_10h, "Past 10 hours", "past_10h_on", true) ]
    else [ step ]
    end
  end.freeze

  MIN_CELL = 5
  SUPPRESSED = "<5".freeze

  # The stage names a person can be stuck at: the first step not reached, or "completed".
  STAGES = (STEPS.drop(1).map(&:key) + [ :completed ]).freeze

  class << self
    # Nested (headline): a step counts only people who reached every earlier step, so it never rises. Ever reached: each step on its own, with the
    # median seconds from the nearest earlier step that has a time (only people with both times in order; a date step counts from midnight UTC of
    # its local date, so same-day steps are day-precise). `until` is inclusive; `cohort` is a referral source key, or :direct for no referral.
    def run(since: nil, until: nil, cohort: nil)
      upto = binding.local_variable_get(:until)
      filtered = !(since.nil? && upto.nil? && cohort.nil?)
      row = connection.select_one(totals_sql(*filters(since, upto, cohort)), "ParticipantFunnel")
      total = row["total"].to_i
      { filtered: filtered, total: total, nested: nested(row, total, filtered), ever_reached: ever_reached(row, total, filtered) }
    end

    def visits(since: nil, until: nil) = Visits.totals(since: since, upto: binding.local_variable_get(:until))

    def visits_by(dimension, since: nil, until: nil) = Visits.by(dimension, since: since, upto: binding.local_variable_get(:until))

    def cohorts(today: Time.current.utc.to_date, since: nil, until: nil) = Cohorts.call(today: today, since: since, upto: binding.local_variable_get(:until))

    # People per funnel_stage, in funnel order, with the median whole days since they reached their latest step.
    def stuck(now: Time.current)
      rows = connection.select_all(
        sanitize([ <<~SQL.squish, { now: now.utc } ]), "ParticipantFunnel"
          SELECT funnel_stage, COUNT(*) AS people,
                 percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (CAST(:now AS timestamp) - funnel_stage_entered_at)) / 86400.0) AS median_days
          FROM insights.funnel_facts GROUP BY funnel_stage
        SQL
      ).to_a.index_by { |row| row["funnel_stage"] }
      STAGES.map do |stage|
        row = rows[stage.to_s]
        people = row ? row["people"].to_i : 0
        hidden = people < MIN_CELL
        { stage: stage, people: hidden ? SUPPRESSED : people, median_days: hidden ? nil : row["median_days"].to_f.round(1) }
      end
    end

    def connection = ActiveRecord::Base.connection

    def sanitize(array) = ActiveRecord::Base.sanitize_sql_array(array)

    # `since` and `until` are UTC dates (anything with #to_date), `until` inclusive; returns [lower, exclusive upper] as dates or nil.
    def bounds(since, upto) = [ since&.to_date, upto && (upto.to_date + 1) ]

    private

    # [where sql, binds] over insights.funnel_facts.
    def filters(since, upto, cohort)
      lower, upper = bounds(since, upto)
      clauses = []
      binds = {}
      (clauses << "signed_up_at >= :lower"; binds[:lower] = lower) if lower
      (clauses << "signed_up_at < :upper"; binds[:upper] = upper) if upper
      if cohort == :direct
        clauses << "referral_source IS NULL"
      elsif cohort
        clauses << "referral_source = :cohort"
        binds[:cohort] = cohort.to_s
      end
      [ clauses.empty? ? "TRUE" : clauses.join(" AND "), binds ]
    end

    # The steps a step is timed from: the ones before it in the nine-step funnel, or (for the extra hour marks) before it in the ever-reached list.
    def earlier_steps(step) = (STEPS.include?(step) ? STEPS : EVER_STEPS).take_while { |candidate| candidate != step }

    def timestamp(step) = step.date ? "CAST(#{step.column} AS timestamp)" : step.column

    # One scan of funnel_facts: per step the people who reached it (ever_), who reached every step up to it (nested_), and the median seconds from the
    # nearest earlier step (median_, timed_).
    def totals_sql(where, binds)
      columns = [ "COUNT(*) AS total" ]
      EVER_STEPS.each_with_index do |step, index|
        key = step.key
        columns << "COUNT(*) FILTER (WHERE #{step.column} IS NOT NULL) AS ever_#{key}"
        if index.positive?
          from = "COALESCE(#{earlier_steps(step).reverse.map { |earlier| timestamp(earlier) }.join(', ')})"
          timed = "#{step.column} IS NOT NULL AND #{from} IS NOT NULL AND #{timestamp(step)} >= #{from}"
          columns << "COUNT(*) FILTER (WHERE #{timed}) AS timed_#{key}"
          columns << "percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM #{timestamp(step)} - #{from})) FILTER (WHERE #{timed}) AS median_#{key}"
        end
      end
      STEPS.each_with_index do |step, index|
        columns << "COUNT(*) FILTER (WHERE #{STEPS.first(index + 1).map { |reached| "#{reached.column} IS NOT NULL" }.join(' AND ')}) AS nested_#{step.key}"
      end
      sanitize([ "SELECT #{columns.join(', ')} FROM insights.funnel_facts WHERE #{where}", binds ])
    end

    def nested(row, total, filtered)
      previous = nil
      STEPS.map do |step|
        count = row["nested_#{step.key}"].to_i
        hidden = filtered && count < MIN_CELL && step.key != :signed_up
        entry = { key: step.key, label: step.label, count: hidden ? SUPPRESSED : count }
        entry[:kept_percent] = previous.nil? ? percent(count, total) : (hidden || previous[:hidden] ? nil : percent(count, previous[:count]))
        entry[:lost] = previous.nil? ? 0 : (hidden || previous[:hidden] ? nil : previous[:count] - count)
        previous = { count: count, hidden: hidden }
        entry
      end
    end

    def ever_reached(row, total, filtered)
      EVER_STEPS.map do |step|
        count = row["ever_#{step.key}"].to_i
        timed = row["timed_#{step.key}"].to_i
        hidden = filtered && count < MIN_CELL && step.key != :signed_up
        timed_hidden = filtered && timed < MIN_CELL
        median = row["median_#{step.key}"]
        {
          key: step.key, label: step.label, count: hidden ? SUPPRESSED : count, kept_percent: hidden ? nil : percent(count, total),
          median_seconds: median.nil? || timed_hidden ? nil : median.to_f.round, timed: step.key == :signed_up ? nil : (timed_hidden ? SUPPRESSED : timed)
        }
      end
    end

    def percent(count, whole) = whole.zero? ? 0.0 : (count * 100.0 / whole).round(1)
  end
end
