# A stored daily aggregate: a number per key per day, no person and no user id (plans/analytics.md, section 5). Stored rather than recomputed
# because deleting people and changing ship statuses rewrites any past recomputed from the live tables. Exact numbers, small cells included (a reader
# applies the small-cell rule when it shows them, Analytics::Report.suppress). Never pruned. Written only by Analytics::Snapshot (`rake analytics:snapshot`).
class AnalyticsDailySnapshot < ApplicationRecord
  KEY_FORMAT = /\A[a-z][a-z0-9_.]{0,59}\z/

  validates :key, format: { with: KEY_FORMAT }
  validates :value, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
