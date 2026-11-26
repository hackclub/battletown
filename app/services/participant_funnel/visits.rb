class ParticipantFunnel
  # The visitor funnel before sign-up, over VISITS (browser sessions), not people: a person on two devices is two visits until they sign in on each.
  # Read from insights.visits and insights.events, so it only has the events collected since the launch (there is no back-fill). Each step counts
  # distinct visits that fired the event, on its own (a visit that skipped a step still counts at the later ones).
  module Visits
    # step key => the event (and, for the page steps, the `step` property) that marks it.
    STEPS = {
      visited: "landing_viewed or any onboarding step",
      age: "age step viewed", prize: "prize step viewed", project: "project step viewed", schedule: "schedule step viewed", signup: "sign-up step viewed",
      ineligible: "answered the age question as not a teen", signup_started: "pressed sign up (a visit that ended in a returning player's sign-in is left out)",
      signed_up: "became a person"
    }.freeze
    PAGE_STEPS = %i[age prize project schedule signup].freeze
    # Breakdown dimension => the insights.visits column. Values are small enums, allowlisted slugs or "other", never a URL.
    DIMENSIONS = { referral_slug: "referral_slug", referrer_kind: "referrer_kind", device_class: "device_class", utm_source: "utm_source" }.freeze
    EVENTS = %w[landing_viewed onboarding_step_viewed onboarding_ineligible signup_started signed_up signed_in].freeze
    NONE = "none".freeze

    class << self
      # { visited: n, age: n, ... } for the window (UTC dates, the end date inclusive). Totals are never suppressed.
      def totals(since:, upto:)
        row = ParticipantFunnel.connection.select_one(query(nil, since, upto), "ParticipantFunnel::Visits") || {}
        STEPS.keys.to_h { |key| [ key, row[key.to_s].to_i ] }
      end

      # One row per value of `dimension`, biggest first: { value:, visited: n, age: n, ... }. A count under MIN_CELL is "<5".
      def by(dimension, since:, upto:)
        column = DIMENSIONS.fetch(dimension.to_sym) { raise ArgumentError, "unknown dimension #{dimension.inspect}" }
        rows = ParticipantFunnel.connection.select_all(query(column, since, upto), "ParticipantFunnel::Visits").to_a
        rows.map do |row|
          counts = STEPS.keys.to_h { |key| [ key, hide(row[key.to_s].to_i) ] }
          { value: row["value"] }.merge(counts)
        end
      end

      private

      def hide(count) = count < MIN_CELL ? SUPPRESSED : count

      def query(column, since, upto)
        lower, upper = ParticipantFunnel.bounds(since, upto)
        clauses = []
        binds = {}
        (clauses << "visits.started_at >= :lower"; binds[:lower] = lower) if lower
        (clauses << "visits.started_at < :upper"; binds[:upper] = upper) if upper
        value = column ? "COALESCE(visits.#{column}, '#{NONE}')" : "CAST(NULL AS text)"
        # (The same button signs returning players in: a visit that ended in the sign-in of an existing account is not a sign-up attempt.)
        steps = PAGE_STEPS.map { |page| "bool_or(events.name = 'onboarding_step_viewed' AND events.props->>'step' = '#{page}') AS #{page}" }
        sql = <<~SQL.squish
          SELECT value,
                 COUNT(*) FILTER (WHERE landing OR any_step) AS visited,
                 #{PAGE_STEPS.map { |page| "COUNT(*) FILTER (WHERE #{page}) AS #{page}" }.join(', ')},
                 COUNT(*) FILTER (WHERE ineligible) AS ineligible,
                 COUNT(*) FILTER (WHERE signup_started) AS signup_started,
                 COUNT(*) FILTER (WHERE signed_up) AS signed_up
          FROM (
            SELECT #{value} AS value,
                   bool_or(events.name = 'landing_viewed') AS landing,
                   bool_or(events.name = 'onboarding_step_viewed') AS any_step,
                   #{steps.join(', ')},
                   bool_or(events.name = 'onboarding_ineligible') AS ineligible,
                   (bool_or(events.name = 'signup_started') AND NOT bool_or(events.name = 'signed_in')) AS signup_started,
                   bool_or(events.name = 'signed_up') AS signed_up
            FROM insights.visits visits
            LEFT JOIN insights.events events ON events.visit_id = visits.visit_id AND events.name IN (#{EVENTS.map { |name| "'#{name}'" }.join(', ')})
            WHERE #{clauses.empty? ? 'TRUE' : clauses.join(' AND ')}
            GROUP BY visits.visit_id#{", #{value}" if column}
          ) per_visit
          GROUP BY value
          ORDER BY visited DESC, value
        SQL
        ParticipantFunnel.sanitize([ sql, binds ])
      end
    end
  end
end
