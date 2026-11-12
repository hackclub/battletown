# Aggregate engagement metrics for /admin/metrics: counts and sums only, never a name, email, Slack id or uid.
#
# A user is "active" on a local date when their net ledger seconds that date reach the 15-minute streak threshold
# (`streaks.quick_minutes` in config/game.yml, via Game::Config). Only counted dates are read, by the game's rule
# (Hours::Days.first_counted_date): hours dated before the local date a user signed up on (minus
# `hours.days_before_signup_counted`) are left out, as they are for the boss and streaks. Dates are the frozen local
# dates on `hour_entries`; "today" is the UTC date (like AdminStats), so the newest day is still filling in. Each
# breakdown is one grouped query (GROUP BY / COUNT DISTINCT / generate_series), so the query count never grows with the
# number of users. The time series are bounded by their date range; the funnel and the dropout view are all-time by
# definition.
class AdminMetrics
  DAYS = 28
  WEEKS = 8
  DROPOUT_DAYS = 14
  # Weeks run Friday to Thursday, like the weekly boss (Date#wday: Friday = 5).
  WEEK_START_WDAY = 5

  Day = Data.define(:date, :active_users, :seconds)
  Week = Data.define(:starts_on, :ends_on, :active_users, :partial)
  Step = Data.define(:label, :count, :percent)
  Bucket = Data.define(:label, :count)
  Metrics = Data.define(:today, :minimum_seconds, :daily, :weekly, :funnel, :dropout)

  FUNNEL_STEPS = {
    signed_up: "Signed up",
    onboarded: "Onboarded",
    hackatime: "Connected Hackatime",
    coded: "First coded day",
    shipped: "First ship submitted",
    approved: "First ship approved",
    purchased: "First purchase"
  }.freeze

  # Every user's ledger rows on counted dates (the same rule as Hours::Totals.counted), read in place of hour_entries.
  COUNTED_ENTRIES = <<~SQL.squish.freeze
    (SELECT hour_entries.user_id, hour_entries.local_date, hour_entries.seconds
     FROM hour_entries
     JOIN users ON users.id = hour_entries.user_id
     WHERE hour_entries.local_date >= users.signed_up_on - CAST(:days_before AS integer)) AS counted_entries
  SQL

  def self.call(today: Time.current.utc.to_date, minimum_seconds: Game::Config.current.quick_seconds)
    new(today: today, minimum_seconds: minimum_seconds).call
  end

  def initialize(today:, minimum_seconds:)
    @today = today
    @minimum = Integer(minimum_seconds)
    @days_before = Hours::Config.current.days_before_signup_counted
  end

  def call
    Metrics.new(today: @today, minimum_seconds: @minimum, daily: daily, weekly: weekly, funnel: funnel, dropout: dropout)
  end

  # The last DAYS local dates, oldest first, zero-filled: active users and the sum of each user's net seconds that
  # day (a user-day below zero, from a correction, counts as zero, like Hours::Totals).
  def daily
    first = @today - (DAYS - 1)
    rows = select(<<~SQL, first: first, last: @today, minimum: @minimum)
      SELECT day::date AS day,
             COUNT(per_day.user_id) FILTER (WHERE per_day.seconds >= :minimum) AS active_users,
             COALESCE(SUM(GREATEST(per_day.seconds, 0)), 0) AS seconds
      FROM generate_series(CAST(:first AS date), CAST(:last AS date), interval '1 day') AS day
      LEFT JOIN (
        SELECT user_id, local_date, SUM(seconds) AS seconds
        FROM #{COUNTED_ENTRIES}
        WHERE local_date BETWEEN :first AND :last
        GROUP BY user_id, local_date
      ) AS per_day ON per_day.local_date = day::date
      GROUP BY day
      ORDER BY day
    SQL
    rows.map { |row| Day.new(date: row["day"].to_date, active_users: row["active_users"].to_i, seconds: row["seconds"].to_i) }
  end

  # The last WEEKS Friday-to-Thursday weeks, oldest first (the newest is the current, partial week): distinct users
  # active on at least one local date in the week.
  def weekly
    last_start = @today - ((@today.wday - WEEK_START_WDAY) % 7)
    first_start = last_start - (7 * (WEEKS - 1))
    rows = select(<<~SQL, first: first_start, last: last_start, today: @today, minimum: @minimum)
      SELECT week_start::date AS week_start, COUNT(DISTINCT active.user_id) AS active_users
      FROM generate_series(CAST(:first AS date), CAST(:last AS date), interval '7 days') AS week_start
      LEFT JOIN (
        SELECT user_id, local_date
        FROM #{COUNTED_ENTRIES}
        WHERE local_date BETWEEN :first AND :today
        GROUP BY user_id, local_date
        HAVING SUM(seconds) >= :minimum
      ) AS active ON active.local_date >= week_start::date AND active.local_date < week_start::date + 7
      GROUP BY week_start
      ORDER BY week_start
    SQL
    rows.map do |row|
      starts_on = row["week_start"].to_date
      Week.new(starts_on: starts_on, ends_on: starts_on + 6, active_users: row["active_users"].to_i, partial: starts_on + 6 > @today)
    end
  end

  # How many users ever reached each step (each step on its own, all-time), and the share of everyone who signed up.
  def funnel
    row = select(<<~SQL, minimum: @minimum).first
      SELECT COUNT(*) AS signed_up,
             COUNT(*) FILTER (WHERE users.onboarded_at IS NOT NULL) AS onboarded,
             COUNT(*) FILTER (WHERE users.id IN (SELECT user_id FROM hackatime_connections)
                                 OR users.id IN (SELECT user_id FROM hour_entries WHERE source = 'hackatime')) AS hackatime,
             COUNT(*) FILTER (WHERE users.id IN (
               SELECT user_id FROM #{COUNTED_ENTRIES} GROUP BY user_id, local_date HAVING SUM(seconds) >= :minimum
             )) AS coded,
             COUNT(*) FILTER (WHERE users.id IN (SELECT user_id FROM ships WHERE submitted_at IS NOT NULL)) AS shipped,
             COUNT(*) FILTER (WHERE users.id IN (SELECT user_id FROM ships WHERE status = 'approved')) AS approved,
             COUNT(*) FILTER (WHERE users.id IN (
               SELECT user_id FROM orders WHERE kind = 'purchase' AND status <> 'cancelled'
             )) AS purchased
      FROM users
    SQL
    total = row["signed_up"].to_i
    FUNNEL_STEPS.map do |key, label|
      count = row[key.to_s].to_i
      Step.new(label: label, count: count, percent: total.zero? ? 0.0 : (count * 100.0 / total).round(1))
    end
  end

  # Users by how many days ago their last active local date was: today, 1..DROPOUT_DAYS, then "more than"
  # (everyone who has ever had an active day is in exactly one bucket). Future local dates are ignored.
  def dropout
    rows = select(<<~SQL, today: @today, minimum: @minimum, cap: DROPOUT_DAYS + 1)
      SELECT LEAST(CAST(:today AS date) - last_day, :cap) AS days_ago, COUNT(*) AS users
      FROM (
        SELECT user_id, MAX(local_date) AS last_day
        FROM (
          SELECT user_id, local_date
          FROM #{COUNTED_ENTRIES}
          WHERE local_date <= :today
          GROUP BY user_id, local_date
          HAVING SUM(seconds) >= :minimum
        ) AS active_days
        GROUP BY user_id
      ) AS last_active
      GROUP BY 1
    SQL
    counts = rows.to_h { |row| [ row["days_ago"].to_i, row["users"].to_i ] }
    (0..DROPOUT_DAYS + 1).map { |days| Bucket.new(label: bucket_label(days), count: counts.fetch(days, 0)) }
  end

  private

  def bucket_label(days)
    case days
    when 0 then "Today"
    when 1 then "1 day ago"
    when DROPOUT_DAYS + 1 then "More than #{DROPOUT_DAYS} days ago"
    else "#{days} days ago"
    end
  end

  def select(sql, **binds)
    sql = ActiveRecord::Base.sanitize_sql_array([ sql, binds.merge(days_before: @days_before) ])
    ActiveRecord::Base.connection.select_all(sql, "AdminMetrics").to_a
  end
end
