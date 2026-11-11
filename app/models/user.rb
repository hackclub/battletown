class User < ApplicationRecord
  PROJECT_KINDS = %w[game website app tool hardware undecided].freeze
  DAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
  ONBOARDING_STEPS = 4

  enum :verification_status, {
    needs_submission: "needs_submission",
    pending: "pending",
    verified: "verified",
    ineligible: "ineligible"
  }, default: :needs_submission, prefix: :verification

  validates :hca_uid, presence: true, uniqueness: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: 254 }, allow_blank: true
  validates :display_name, length: { maximum: 100 }
  validates :prize_key, inclusion: { in: ->(_) { Prize.keys } }, allow_nil: true
  validates :project_kind, inclusion: { in: PROJECT_KINDS }, allow_nil: true
  validates :project_idea, length: { maximum: 500 }
  validates :coding_time, format: { with: /\A([01]\d|2[0-3]):[0-5]\d\z/ }, allow_nil: true
  validates :time_zone, inclusion: { in: ->(_) { ActiveSupport::TimeZone.all.map(&:name) } }, allow_nil: true
  validates :referral_source, format: { with: Referral::FORMAT }, allow_nil: true
  validates :coding_days, numericality: { in: 0..127, only_integer: true }
  validates :onboarding_step, numericality: { in: 0..ONBOARDING_STEPS, only_integer: true }

  # STUB: there is no admin role yet, so nobody is an admin and `admin_tool` UI is never shown.
  # The project owner must decide how admins are identified (e.g. an allowlist of Hack Club Auth ids or a column)
  # and implement it here, server-side. Do not trust any client-supplied value.
  def admin?
    false
  end

  # Two simultaneous first logins both try to INSERT; the unique index rejects one, which then retries
  # and finds the winner's row instead of surfacing a 500.
  def self.from_hca_claims!(claims, referral_source: nil)
    attempts = 0
    begin
      user = find_or_initialize_by(hca_uid: claims.fetch("sub"))
      user.referral_source = referral_source if user.new_record?
      user.apply_hca_claims(claims)
      user.save!
      user
    rescue ActiveRecord::RecordNotUnique
      retry if (attempts += 1) < 2
      raise
    end
  end

  # Only store what we need. phone and birthdate claims are requested but intentionally ignored (not stored,
  # not logged) pending a privacy decision. The address is used in memory to default `time_zone` (only while it
  # is blank, so a zone the user chose is never overwritten) and is otherwise dropped: only the zone is stored.
  def apply_hca_claims(claims)
    self.email = claims["email"]
    self.display_name = (claims["name"].presence || claims["nickname"].presence || display_name)&.to_s&.first(100)
    self.slack_id = claims["slack_id"]
    status = claims["verification_status"].to_s
    self.verification_status = status if self.class.verification_statuses.key?(status)
    self.ysws_eligible = claims["ysws_eligible"] == true
    self.time_zone = AddressTimeZone.zone_name(claims) if time_zone.blank?
  end

  def onboarded? = onboarded_at.present?

  def coding_day_names
    DAYS.each_with_index.filter_map { |day, index| day if coding_days.anybits?(1 << index) }
  end

  def coding_day_names=(names)
    self.coding_days = Array(names).sum { |name| (index = DAYS.index(name.to_s)) ? 1 << index : 0 }
  end

  def prize = Prize.find(prize_key)
end
