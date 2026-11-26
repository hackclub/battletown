module Analytics
  # Who is never measured: staff (ADMIN_HCA_UIDS), simulated players (hca_uid starts with "sim!") and the testers in ANALYTICS_EXCLUDE_HCA_UIDS
  # (comma separated, empty by default). One definition for the write path; the stored flag on users (AnalyticsExclusion) is the same rule.
  module Exclusion
    ENV_KEY = "ANALYTICS_EXCLUDE_HCA_UIDS".freeze
    SIM_PREFIX = "sim!".freeze

    class << self
      def listed_uids(raw = ENV[ENV_KEY]) = raw.to_s.split(",").map(&:strip).reject(&:empty?).uniq

      # SQL for "this person is measured", for the existing staff metrics (and the scope User.analytics_included): the stored flag, plus the live
      # lists, so a change to ADMIN_HCA_UIDS or ANALYTICS_EXCLUDE_HCA_UIDS (or a sim created without the flag) takes effect before the flag is refreshed.
      def included_sql(table = "users")
        conditions = [ "#{table}.analytics_excluded = FALSE", "#{table}.hca_uid NOT LIKE 'sim!%'" ]
        named = (AdminAllowlist.uids + listed_uids).uniq
        conditions << "#{table}.hca_uid NOT IN (#{named.map { |uid| User.connection.quote(uid) }.join(', ')})" if named.any?
        conditions.join(" AND ")
      end

      def uid?(uid)
        uid = uid.to_s
        uid.present? && (uid.start_with?(SIM_PREFIX) || AdminAllowlist.include?(uid) || listed_uids.include?(uid))
      end

      # Sets users.analytics_excluded from the current lists for every user and purges what was recorded about the excluded ones. Returns the counts
      # (people only). Run after the lists change (`rake analytics:refresh_exclusions`) and once after the first deploy.
      def refresh_all!
        excluded_ids = User.pluck(:id, :hca_uid).filter_map { |id, uid| id if uid?(uid) }
        marked = User.where(id: excluded_ids).where(analytics_excluded: false).update_all(analytics_excluded: true)
        cleared = User.where.not(id: excluded_ids).where(analytics_excluded: true).update_all(analytics_excluded: false)
        purge!(excluded_ids)
        { excluded: excluded_ids.size, marked: marked, cleared: cleared }
      end

      # Removes everything recorded about these people (and the anonymous visit named by `token`, when it is theirs or nobody's), because they are
      # excluded: the visits (their events go with them), any events left and their days of presence. Used at sign-in and by
      # `rake analytics:refresh_exclusions`; the only analytics deletion that is not a person's own request.
      def purge!(user_ids, token: nil)
        user_ids = Array(user_ids)
        AnalyticsVisit.where(user_id: user_ids).delete_all
        AnalyticsVisit.where(visit_key: token, user_id: nil).delete_all if token
        AnalyticsEvent.where(user_id: user_ids).delete_all
        AnalyticsSiteDay.where(user_id: user_ids).delete_all
      end
    end
  end
end
