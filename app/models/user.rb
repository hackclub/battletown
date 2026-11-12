class User < ApplicationRecord
  PROJECT_KINDS = %w[game website app tool hardware undecided].freeze
  DAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
  ONBOARDING_STEPS = 4

  # Deleted by the database (ON DELETE CASCADE), so the data-deletion API removes the Hackatime tokens too.
  has_one :hackatime_connection, dependent: nil

  enum :verification_status, {
    needs_submission: "needs_submission",
    pending: "pending",
    verified: "verified",
    ineligible: "ineligible"
  }, default: :needs_submission, prefix: :verification

  has_many :projects, dependent: :destroy
  has_many :hackatime_links, dependent: :destroy
  has_many :ships, dependent: :destroy
  has_many :link_suggestions, through: :projects
  has_many :orders
  has_many :address_offers, dependent: nil
  # Deleted by the database (ON DELETE CASCADE).
  has_many :merch_claims, dependent: nil
  # Private staff notes about this person; deleted by the database (ON DELETE CASCADE).
  has_many :user_notes, dependent: nil

  validates :hca_uid, presence: true, uniqueness: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: 254 }, allow_blank: true
  validates :display_name, length: { maximum: 100 }
  validates :prize_key, inclusion: { in: ->(_) { Prize.keys } }, allow_nil: true
  # Every key ever offered stays valid for people who already picked it (archived items included), but a NEW pick must be an
  # item that is still on offer.
  validate :prize_still_offered, if: :prize_key_changed?
  validates :project_kind, inclusion: { in: PROJECT_KINDS }, allow_nil: true
  validates :project_idea, length: { maximum: 500 }
  validates :coding_time, format: { with: /\A([01]\d|2[0-3]):[0-5]\d\z/ }, allow_nil: true
  validates :time_zone, inclusion: { in: ->(_) { ActiveSupport::TimeZone.all.map(&:name) } }, allow_nil: true
  validates :referral_source, format: { with: Referral::FORMAT }, allow_nil: true
  validates :coding_days, numericality: { in: 0..127, only_integer: true }
  validates :onboarding_step, numericality: { in: 0..ONBOARDING_STEPS, only_integer: true }

  before_save :set_signed_up_on, if: :signed_up_on_open?

  # Admins are the Hack Club Auth ids in the ADMIN_HCA_UIDS env var (see AdminAllowlist). Checked server-side
  # against the stored hca_uid on every call; nothing client-supplied is trusted.
  def admin? = AdminAllowlist.include?(hca_uid)

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
    self.verification_checked_at = Time.current
    self.time_zone = AddressTimeZone.zone_name(claims) if time_zone.blank?
  end

  def onboarded? = onboarded_at.present?

  # The "no email at all" switch (Notifications::Email, behind the `email` flag): set by the settings page and by the
  # one-click unsubscribe link in every email.
  def email_opted_out? = email_opted_out_at.present?

  # Where this person stands on spending coins, the one place that decides it (Shop::Spendable and every note, banner
  # and staff page read it; nothing else looks at verification_status or ysws_eligible for this). One of:
  #   :ready        can spend
  #   :unverified   not verified with Hack Club yet (the verify note)
  #   :stale        verified, but the sign-in copy is older than the maximum age (asks them to sign in again)
  #   :not_eligible verified, but not eligible for Hack Club YSWS programs (never says why)
  # With the `eligibility_gate` flag OFF only the first two exist: verified spends, exactly as before the gate.
  def spend_state
    return :unverified unless verification_verified?
    return :ready unless Features.enabled?(:eligibility_gate, self)
    return :stale if verification_stale?

    ysws_eligible? ? :ready : :not_eligible
  end

  def can_spend_coins? = spend_state == :ready

  # No stored check time (never signed in since the column existed) counts as old.
  def verification_stale?
    verification_checked_at.nil? || verification_checked_at < Eligibility::Config.current.max_age.ago
  end

  # The one project hours should count toward right now (nil until they have one). Other features read this.
  def active_project = projects.find_by(active: true)

  def coding_day_names
    DAYS.each_with_index.filter_map { |day, index| day if coding_days.anybits?(1 << index) }
  end

  def coding_day_names=(names)
    self.coding_days = Array(names).sum { |name| (index = DAYS.index(name.to_s)) ? 1 << index : 0 }
  end

  def prize = Prize.find(prize_key)

  private

  def prize_still_offered
    return if prize_key.nil? || errors.include?(:prize_key)

    errors.add(:prize_key, "is no longer in the shop: pick another") unless Prize.find(prize_key)&.active?
  end

  # `signed_up_on` is the local date the account was created on, in the user's zone: the game counts hours from it
  # (Hours::Days.first_counted_date). It is set when the account is created and follows the zone only while onboarding
  # (where the zone is chosen) is unfinished; after that it is frozen, so a later zone change never moves the cutoff.
  def signed_up_on_open? = signed_up_on.nil? || (will_save_change_to_time_zone? && onboarded_at_in_database.nil?)

  def set_signed_up_on
    self.created_at ||= Time.current
    self.signed_up_on = Hours::Days.local_date(created_at, self)
  end
end
