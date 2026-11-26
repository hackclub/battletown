# One allowlisted event (config/analytics.yml): a name, a few bounded properties (jsonb, at most 400 bytes, a database check), when, and who it is
# about (a visit while they are anonymous, a user once they have signed in). Written only through Analytics.track, which validates the name and
# every property; the table is never pruned. `dedupe_key` makes an at-least-once emitter idempotent per user (unique index, ON CONFLICT DO NOTHING).
class AnalyticsEvent < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :visit, class_name: "AnalyticsVisit", optional: true, inverse_of: :events
end
