# A shop order: a request for one item, paid for in coins. Created only through Shop::Purchase / Shop::ClaimSticker and
# changed only through Shop::Cancel / Shop::Fulfill (they hold the user lock and keep the coin ledger in step). It holds
# no address: the team arranges delivery with the person on Slack. `coins` is the price at order time.
class Order < ApplicationRecord
  KINDS = %w[purchase signup_sticker].freeze
  STATUSES = %w[requested fulfilled cancelled].freeze
  KEY_MAX = 100

  belongs_to :user

  validates :prize_key, inclusion: { in: ->(_) { Prize.keys } }
  validates :prize_name, presence: true, length: { maximum: 100 }
  validates :coins, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :idempotency_key, presence: true, length: { maximum: KEY_MAX }
  validate :price_matches_kind

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  # Requested first (the staff queue), then the rest, newest first inside each group.
  scope :queue_order, -> { order(Arel.sql("CASE status WHEN 'requested' THEN 0 ELSE 1 END"), created_at: :desc, id: :desc) }

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end

  def signup_sticker? = kind == "signup_sticker"

  def prize = Prize.find(prize_key)

  # The name as it was when ordered, so a retired catalogue item still reads properly.
  def display_name = prize_name.presence || prize&.name || "Item"

  def emoji = prize&.emoji

  private

  def price_matches_kind
    return if coins.nil?

    errors.add(:coins, "must be 0 for the signup sticker") if signup_sticker? && coins.positive?
    errors.add(:coins, "must be more than 0 for a purchase") if kind == "purchase" && coins.zero?
  end
end
