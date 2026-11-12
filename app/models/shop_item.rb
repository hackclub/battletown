# One item in the shop, in the database so staff change it at /admin/shop instead of deploying (docs/CONTRACT.md, "Shop
# catalogue"). Everything that READS the catalogue goes through the `Prize` facade, which wraps these rows; write here only
# from the admin controller, ShopItems::Seed and tests.
#
# - `key` names the item in `orders.prize_key` and `users.prize_key` (text, no foreign key): it is set once and never changes,
#   and a row is never deleted, so those stay valid. To take an item off sale, archive it (`active: false`): hidden from the
#   shop, landing and onboarding pick, still valid for people who picked it and for orders already made.
# - The one price is `coins`. Orders copy the price and name when they are made, so changing it never changes a past order.
# - `kind` is `regular` (bought with coins) or `free_signup` (the sticker anyone can claim once; at most one exists).
# - The picture is the re-encoded WebP from ShipImages::Processor (the original upload is never kept). List queries leave its
#   bytes out (`without_content`); reading `image_content` on such a row raises MissingAttributeError. `lock_version` makes two
#   admins saving the same item at once a friendly "someone else changed it" instead of a silent overwrite.
class ShopItem < ApplicationRecord
  KEY_FORMAT = /\A[a-z0-9_]{1,60}\z/
  TIERS = %w[daily weekly shop].freeze
  KINDS = %w[regular free_signup].freeze
  NAME_MAX = 60
  DESCRIPTION_MAX = 200
  EMOJI_MAX = 8
  COINS_MAX = 1_000_000
  CONTENT_TYPE = "image/webp".freeze

  attr_readonly :key, :kind

  before_validation :normalize_text

  validates :key, format: { with: KEY_FORMAT, message: "can only use lowercase letters, numbers and underscores (up to 60)" },
                  uniqueness: { message: "is already used by another item" }
  validates :name, presence: true, length: { maximum: NAME_MAX }
  validates :description, length: { maximum: DESCRIPTION_MAX }
  validates :emoji, length: { maximum: EMOJI_MAX }, allow_nil: true
  validates :coins, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: COINS_MAX }
  validates :tier, inclusion: { in: TIERS }
  validates :kind, inclusion: { in: KINDS }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :price_matches_kind
  validate :only_one_free_signup, on: :create

  after_commit { Prize.reload! }

  scope :without_content, -> { select(column_names - [ "image_content" ]) }
  scope :in_order, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }
  scope :archived, -> { where(active: false) }

  def free_signup? = kind == "free_signup"

  # Whether it has a picture. Safe on a row loaded without its bytes.
  def image? = image_sha256.present?

  # The picture, served by ShopItemImagesController. The version changes whenever the picture does, so the long cache is safe.
  def image_path
    return unless image?

    Rails.application.routes.url_helpers.shop_item_image_path(key, v: image_sha256.first(12))
  end

  # The bytes of the picture, loaded on their own (the one place that needs them).
  def self.image_content_for(key) = where(key: key.to_s).pick(:image_content)

  # Stores a picture made by ShipImages::Processor (a ShipImages::Processed).
  def attach_image(processed)
    assign_attributes(image_content: processed.content, image_width: processed.width, image_height: processed.height,
                      image_byte_size: processed.byte_size, image_sha256: processed.sha256)
  end

  def remove_image
    assign_attributes(image_content: nil, image_width: nil, image_height: nil, image_byte_size: nil, image_sha256: nil)
  end

  private

  def normalize_text
    self.name = name.to_s.squish
    self.description = description.to_s.squish
    self.emoji = emoji.to_s.strip.presence
  end

  def price_matches_kind
    return if coins.nil?

    errors.add(:coins, "must be 0 for the free signup item") if free_signup? && coins.positive?
    errors.add(:coins, "must be more than 0 (an item that costs nothing can't be bought)") if kind == "regular" && coins.zero?
  end

  def only_one_free_signup
    return unless free_signup? && self.class.where(kind: "free_signup").exists?

    errors.add(:base, "There is already a free signup item: edit that one instead of adding another.")
  end
end
