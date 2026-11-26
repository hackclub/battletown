class ParticipantFunnel
  # Sign-up weeks (Friday to Thursday, like the weekly boss) with how many came back the day after and a week after signing up. "Came back on day N" means
  # a day of presence (insights.site_days) or counted hours on the local date N days after sign-up. Only people whose day N has already passed are in
  # that column's denominator. A count under MIN_CELL is "<5" (zero included: a zero in a small week would say that nobody came back).
  module Cohorts
    WEEK_START_WDAY = 5
    RETURN_DAYS = [ 1, 7 ].freeze

    class << self
      def call(today:, since:, upto:)
        lower, upper = ParticipantFunnel.bounds(since, upto)
        clauses = [ "TRUE" ]
        binds = { today: today.to_date, week_start: WEEK_START_WDAY }
        (clauses << "facts.signed_up_on >= :lower"; binds[:lower] = lower) if lower
        (clauses << "facts.signed_up_on < :upper"; binds[:upper] = upper) if upper
        rows = ParticipantFunnel.connection.select_all(ParticipantFunnel.sanitize([ sql(clauses.join(" AND ")), binds ]), "ParticipantFunnel::Cohorts")
        rows.map { |row| entry(row) }
      end

      private

      def entry(row)
        result = { week_starts_on: row["week_starts_on"].to_date, people: row["people"].to_i }
        RETURN_DAYS.each do |day|
          eligible = row["eligible_#{day}"].to_i
          returned = row["returned_#{day}"].to_i
          result[:"day#{day}"] = {
            eligible: hide(eligible), returned: hide(returned),
            percent: eligible < MIN_CELL || returned < MIN_CELL ? nil : (returned * 100.0 / eligible).round(1)
          }
        end
        result
      end

      def hide(count) = count < MIN_CELL ? SUPPRESSED : count

      def returned(day)
        <<~SQL.squish
          (EXISTS (SELECT 1 FROM insights.site_days WHERE site_days.person_id = facts.person_id AND site_days.day = facts.signed_up_on + #{day})
           OR EXISTS (SELECT 1 FROM insights.hour_days WHERE hour_days.person_id = facts.person_id AND hour_days.local_date = facts.signed_up_on + #{day}
                      AND hour_days.counted AND hour_days.seconds > 0))
        SQL
      end

      def sql(where)
        columns = RETURN_DAYS.flat_map do |day|
          [ "COUNT(*) FILTER (WHERE signed_up_on + #{day} <= :today) AS eligible_#{day}",
            "COUNT(*) FILTER (WHERE signed_up_on + #{day} <= :today AND returned_#{day}) AS returned_#{day}" ]
        end
        returns = RETURN_DAYS.map { |day| "#{returned(day)} AS returned_#{day}" }
        <<~SQL.squish
          SELECT week_starts_on, COUNT(*) AS people, #{columns.join(', ')}
          FROM (
            SELECT facts.signed_up_on,
                   facts.signed_up_on - CAST((EXTRACT(DOW FROM facts.signed_up_on)::integer - :week_start + 7) % 7 AS integer) AS week_starts_on,
                   #{returns.join(', ')}
            FROM insights.funnel_facts facts WHERE #{where}
          ) per_person
          GROUP BY week_starts_on ORDER BY week_starts_on
        SQL
      end
    end
  end
end
