# Who is never measured (plans/analytics.md, section 1.6): staff (ADMIN_HCA_UIDS), simulated players (hca_uid "sim!...") and the testers listed in
# ANALYTICS_EXCLUDE_HCA_UIDS. The flag is refreshed on every save (a sign-in saves the user), so a change to the lists takes effect at the next
# sign-in (or `rake analytics:refresh_exclusions`). The rule itself lives in Analytics::Exclusion; one `include` line in User.
module AnalyticsExclusion
  extend ActiveSupport::Concern

  included do
    scope :analytics_included, -> { where(Analytics::Exclusion.included_sql(table_name)) }
    before_save :refresh_analytics_excluded
  end

  private

  def refresh_analytics_excluded
    self.analytics_excluded = Analytics::Exclusion.uid?(hca_uid)
  end
end
