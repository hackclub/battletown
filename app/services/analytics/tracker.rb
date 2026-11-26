module Analytics
  # The write behind Analytics.track, after its checks. One insert; with `once:` an insert that does nothing when this person already has an
  # event with that key (the partial unique index), so a settle or sync that runs twice records once.
  module Tracker
    DEDUPE_INDEX = :index_analytics_events_on_user_id_and_dedupe_key

    class << self
      def write(name, props, user:, visit:, once:)
        row = { name: name.to_s, props: props, occurred_at: Time.current, visit_id: visit_id_for(visit, user), user_id: user&.id, dedupe_key: dedupe_key(once) }
        return if row[:user_id].nil? && row[:visit_id].nil? # nobody to attach it to (no cookie, no account)

        if row[:dedupe_key]
          AnalyticsEvent.insert_all([ row ], unique_by: DEDUPE_INDEX)
        else
          AnalyticsEvent.insert_all!([ row ])
        end
      end

      private

      # A visit another person signed in on (a shared computer) is not this person's trail.
      def visit_id_for(visit, user)
        return unless visit
        return if user && visit.user_id && visit.user_id != user.id

        visit.id
      end

      def dedupe_key(once)
        return if once.nil?

        key = once.to_s
        raise Events::Invalid, "once: must be 1 to #{Events::MAX_DEDUPE_KEY} characters" unless key.length.between?(1, Events::MAX_DEDUPE_KEY)

        key
      end
    end
  end
end
