# A screenshot attached to a ship (flag `ship_screenshots`). `content` is always the re-encoded WebP that
# ShipImages::Processor produced: the original upload is never stored, so no EXIF/GPS, no embedded text and no file name
# survive. Up to three per ship (`position` 1..3, unique per ship), deleted with the ship and with the user by the
# database (ON DELETE CASCADE). Only the owner and staff can see one (ShipImagesController).
#
# Listing a ship's images never loads the bytes: `Ship#images` uses `without_content`, and reading `content` on such a
# row raises ActiveModel::MissingAttributeError. Load a row's bytes with `ShipImage.find_by!(...)` only to serve it.
class ShipImage < ApplicationRecord
  POSITIONS = (1..3).freeze
  ALT_MAX = 140
  # The schema's hard ceiling (db check ship_images_byte_size_check); config can lower the upload limit, never raise it.
  MAX_BYTES_CEILING = 5_000_000
  CONTENT_TYPE = "image/webp".freeze

  belongs_to :ship
  belongs_to :user

  before_validation :normalize_alt

  validates :position, inclusion: { in: POSITIONS }
  validates :width, :height, numericality: { only_integer: true, greater_than: 0 }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_BYTES_CEILING }
  validates :sha256, format: { with: /\A\h{64}\z/ }
  validates :alt, length: { maximum: ALT_MAX }
  validate :belongs_to_the_ships_owner

  scope :without_content, -> { select(column_names - [ "content" ]) }
  scope :in_order, -> { order(:position) }

  # What a screenshot says to a screen reader: the teen's own words, else a plain default.
  def alt_text = alt.presence || "Screenshot #{position}"

  private

  def normalize_alt
    self.alt = alt.to_s.squish.presence
  end

  def belongs_to_the_ships_owner
    errors.add(:user, "must be the ship's owner") if ship && user_id != ship.user_id
  end
end
