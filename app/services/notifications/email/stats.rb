module Notifications
  module Email
    # Aggregates for /admin/email: how many email rows were created per week, by status. Counts only (never an address,
    # a name or an id). Weeks run Friday to Thursday like the weekly boss, in UTC, newest first; one grouped query.
    # Finished rows are pruned after `retention_days` (config/notifications.yml), so older weeks fill in only as far as
    # that.
    module Stats
      WEEKS = 8
      WEEK_START_WDAY = 5
      Week = Data.define(:starts_on, :ends_on, :counts, :total, :partial) do
        def count(status) = counts.fetch(status, 0)
      end

      # Postgres: the Friday on or before created_at's UTC date (DOW: Sunday 0 .. Saturday 6).
      WEEK_START_SQL = "(created_at::date - ((EXTRACT(DOW FROM created_at)::int + 2) % 7))".freeze

      module_function

      def weekly(today: Time.current.utc.to_date, weeks: WEEKS)
        last_start = today - ((today.wday - WEEK_START_WDAY) % 7)
        first_start = last_start - 7 * (weeks - 1)
        grouped = Notification.where(channel: Email::CHANNEL, created_at: first_start.beginning_of_day..).group(Arel.sql(WEEK_START_SQL), :status).count
        by_week = grouped.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |((start, status), count), memo|
          memo[start.to_date][status] = count
        end

        (0...weeks).map do |index|
          starts_on = last_start - 7 * index
          counts = by_week.fetch(starts_on, {})
          Week.new(starts_on: starts_on, ends_on: starts_on + 6, counts: counts, total: counts.values.sum, partial: index.zero?)
        end
      end
    end
  end
end
