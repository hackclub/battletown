# One browser session, first-touch (projects/battletown/plans/analytics.md, section 1.2): a random visit_key (the session token) that lives only in the encrypted session
# cookie, when it started, where it came from (a referral slug, allowlisted utm values, the KIND of referrer) and a coarse device class. No IP,
# user agent, referrer or landing URL column exists, by design. `user_id` is stamped when the person signs in (Analytics::Visitor#link!),
# so the pre-sign-up trail is deleted with them (ON DELETE CASCADE). Never deleted on a schedule: nothing prunes analytics.
class AnalyticsVisit < ApplicationRecord
  REFERRER_KINDS = %w[direct search social hack_club other].freeze
  DEVICE_CLASSES = %w[desktop mobile tablet unknown].freeze

  belongs_to :user, optional: true
  # Deleted by the database with the visit (ON DELETE CASCADE).
  has_many :events, class_name: "AnalyticsEvent", foreign_key: :visit_id, inverse_of: :visit, dependent: nil

  validates :referrer_kind, inclusion: { in: REFERRER_KINDS }
  validates :device_class, inclusion: { in: DEVICE_CLASSES }
end
