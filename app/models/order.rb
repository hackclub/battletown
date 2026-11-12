# A shop order: a request for one item, paid for in coins. Created only through Shop::Purchase / Shop::ClaimSticker and
# changed only through the Orders services (Hold, Release, Ship, Fulfil, Cancel, Refund, AddNote, UpdateTracking; they hold
# the user lock, write the order_events history and keep the coin ledger in step). It holds no address: the team arranges
# delivery with the person on Slack. `coins` is the price at order time.
#
# Statuses: requested (waiting for the team), on_hold (parked by staff; the buyer still sees "Requested"), shipped, fulfilled,
# cancelled (before it was sent) and refunded (after it was sent). The allowed moves live in Orders::StateMachine.
class Order < ApplicationRecord
  KINDS = %w[purchase signup_sticker].freeze
  STATUSES = %w[requested on_hold shipped fulfilled cancelled refunded].freeze
  # Not finished: the team still has something to do (or is waiting for the parcel to arrive).
  OPEN_STATUSES = %w[requested on_hold shipped].freeze
  KEY_MAX = 100
  TRACKING_NUMBER_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9 -]{2,59}\z/
  TRACKING_LABEL_MAX = 40

  has_many :events, class_name: "OrderEvent", dependent: nil
  belongs_to :user

  validates :prize_key, inclusion: { in: ->(_) { Prize.keys } }
  validates :prize_name, presence: true, length: { maximum: 100 }
  validates :coins, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :idempotency_key, presence: true, length: { maximum: KEY_MAX }
  validate :price_matches_kind
  validate :tracking_is_well_formed, if: :tracking_changed?

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :unfinished, -> { where(status: OPEN_STATUSES) }
  # What the team has to act on first: requested, then on hold, then shipped, then the finished ones; newest first inside each.
  scope :queue_order, lambda {
    order(Arel.sql("CASE status WHEN 'requested' THEN 0 WHEN 'on_hold' THEN 1 WHEN 'shipped' THEN 2 ELSE 3 END"), created_at: :desc, id: :desc)
  }

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end

  def signup_sticker? = kind == "signup_sticker"

  def prize = Prize.find(prize_key)

  # The name as it was when ordered, so a retired catalogue item still reads properly.
  def display_name = prize_name.presence || prize&.name || "Item"

  def emoji = prize&.emoji

  # What the buyer is shown: a hold is staff-only, so it reads exactly like a request.
  def buyer_status = on_hold? ? "requested" : status

  def unfinished? = OPEN_STATUSES.include?(status)

  def tracking? = tracking_number.present?

  # Whole days since the order was placed (never negative).
  def age_days(now = Time.current) = [ ((now - created_at) / 1.day).floor, 0 ].max

  # Waiting for the team for `overdue_days` or more (only `requested`; a hold, a sent order or a finished one is not overdue).
  def overdue?(now = Time.current) = requested? && age_days(now) >= Orders::Config.current.overdue_days

  private

  def price_matches_kind
    return if coins.nil?

    errors.add(:coins, "must be 0 for the signup sticker") if signup_sticker? && coins.positive?
    errors.add(:coins, "must be more than 0 for a purchase") if kind == "purchase" && coins.zero?
  end

  def tracking_changed? = tracking_carrier_changed? || tracking_number_changed? || tracking_label_changed?

  def tracking_is_well_formed
    if tracking_number.blank? && tracking_carrier.blank?
      errors.add(:tracking_label, "needs a carrier") if tracking_label.present?
      return
    end

    errors.add(:tracking_carrier, "must be one of the listed carriers") unless Orders::Config.current.carrier(tracking_carrier)
    errors.add(:tracking_number, "is needed with a carrier") if tracking_number.blank?
    errors.add(:tracking_number, "can only use letters, numbers, spaces and hyphens (3 to 60 characters)") if tracking_number.present? && !tracking_number.match?(TRACKING_NUMBER_FORMAT)
    errors.add(:tracking_label, "is only for the carrier \"Other\"") if tracking_label.present? && tracking_carrier != "other"
    errors.add(:tracking_label, "is too long (at most #{TRACKING_LABEL_MAX} characters)") if tracking_label.to_s.length > TRACKING_LABEL_MAX
    errors.add(:tracking_label, "can't have control characters") if tracking_label.to_s.match?(/[[:cntrl:]]/)
    errors.add(:base, "Tracking can only be added once the order is shipped") unless shipped_at
  end
end
