# The weekly community boss. One row per week, Friday to Thursday, with its health in seconds of coded time.
# Damage is never stored: it is the coded hours on the ships submitted during the boss's week (Bosses::Damage); coding alone
# never hurts the boss.
# `defeated_at` is set once by Bosses::CheckDefeat and is never cleared. A boss is not about a person.
#
# A boss may have its own picture, uploaded by staff: the re-encoded WebP from ShipImages::Processor (the original upload is never
# kept), with its alt text. Without one the boss uses the built-in picture named by `art_key`. List queries leave the bytes out
# (`without_art_content`); reading `art_content` on such a row raises MissingAttributeError. `lock_version` makes two admins saving
# the same boss at once a friendly "someone else changed it" instead of a silent overwrite.
class Boss < ApplicationRecord
  # Same-origin illustration slots: each key is an image at app/assets/images/bosses/<key>.webp, with its alt text.
  ARTS = {
    "placeholder" => "A tall armoured boss in a white cat-eared helmet, holding a huge spiked blade"
  }.freeze
  ART_KEYS = ARTS.keys.freeze
  ART_ALT_MAX = 200
  ART_CONTENT_TYPE = "image/webp".freeze
  NAME_LENGTH = 1..60
  # The most health a boss can have (100,000 hours); keeps the integer column far from overflow.
  MAX_HP_SECONDS = 360_000_000
  # A boss counts as started once its first day has begun in the earliest time zone on Earth (UTC+14), so an
  # HP edit can never move anybody's bar once anybody could have started hitting it. Any hours already on its dates
  # start it too: Hours::Credit accepts a user's tomorrow, which in UTC+14 is a date no zone has reached yet.
  EARLIEST_ZONE = "Pacific/Kiritimati".freeze

  scope :covering, ->(date) { where(starts_on: ..date, ends_on: date..) }
  scope :chronological, -> { order(:starts_on) }
  scope :without_art_content, -> { select(column_names - [ "art_content" ]) }

  normalizes :name, with: ->(name) { name.to_s.squish }
  normalizes :art_alt, with: ->(alt) { alt.to_s.squish.presence }

  before_validation :default_ends_on, on: :create

  validates :name, length: { in: NAME_LENGTH }
  validates :art_key, inclusion: { in: ART_KEYS }
  validates :starts_on, :ends_on, presence: true
  validates :starts_on, uniqueness: true
  validates :art_alt, length: { maximum: ART_ALT_MAX }
  validates :art_alt, presence: { message: "is needed to describe the picture" }, if: :art?
  validates :hp_seconds, numericality: { only_integer: true, in: 1..MAX_HP_SECONDS }
  validate :ends_on_not_before_starts_on
  validate :week_is_friday_to_thursday, on: :create
  validate :no_overlap
  validate :hp_fixed_once_started, on: :update
  validate :dates_fixed, on: :update
  validate :defeat_is_final, on: :update

  # Whether it has its own uploaded picture. Safe on a row loaded without its bytes.
  def art? = art_sha256.present?

  # The picture the pages show: the uploaded one (served by BossArtsController; the version changes whenever the picture does, so
  # the long cache is safe), else the built-in asset path (for image_tag).
  def art_path
    return "bosses/#{art_key}.webp" unless art?

    Rails.application.routes.url_helpers.boss_art_path(id, v: art_sha256.first(12))
  end

  # What a screen reader hears for the picture: the staff-written text for an uploaded one, else the built-in picture's
  # description, else a plain fallback.
  def art_alt_text = (art_alt if art?) || ARTS[art_key] || "The boss, #{name}"

  # The bytes of an uploaded picture, loaded on their own (the one place that needs them).
  def self.art_content_for(id) = where(id: id).pick(:art_content)

  # Stores a picture made by ShipImages::Processor (a ShipImages::Processed). The alt text is set separately (`art_alt=`).
  def attach_art(processed)
    assign_attributes(art_content: processed.content, art_width: processed.width, art_height: processed.height,
                      art_byte_size: processed.byte_size, art_sha256: processed.sha256)
  end

  # Back to the built-in picture. The alt text only describes an uploaded picture, so it goes too.
  def remove_art
    assign_attributes(art_content: nil, art_width: nil, art_height: nil, art_byte_size: nil, art_sha256: nil, art_alt: nil)
  end

  # Takes another boss's picture and alt text (the form's "Use last week's picture"). The other boss may have been loaded
  # without its bytes. Does nothing when it has no picture.
  def copy_art_from(other)
    return unless other.art?

    assign_attributes(art_content: self.class.art_content_for(other.id), art_width: other.art_width, art_height: other.art_height,
                      art_byte_size: other.art_byte_size, art_sha256: other.art_sha256, art_alt: other.art_alt)
  end

  def range = starts_on..ends_on

  def defeated? = defeated_at.present?

  # Whole hours, or a decimal (two places) when the health is not a whole number of hours.
  def hp_hours
    return if hp_seconds.nil?

    (hp_seconds % 3600).zero? ? hp_seconds / 3600 : (hp_seconds / 3600.0).round(2)
  end

  # Admins enter hours; anything that is not a number leaves the health blank so validation reports it.
  def hp_hours=(value)
    raise ArgumentError unless value.to_s.strip.match?(/\A\d{1,6}(?:\.\d{1,6})?\z/) # a plain decimal only (no exponents to expand)

    self.hp_seconds = (BigDecimal(value.to_s.strip) * 3600).round
  rescue ArgumentError, FloatDomainError
    self.hp_seconds = nil
  end

  def started?(now: Time.current)
    return false if starts_on.nil?

    begun?(now: now) || (ends_on.present? && HourEntry.exists?(local_date: range))
  end

  # Whether anybody's calendar could show the boss yet: its first day has begun in UTC+14. Dates only (no query), so the
  # public picture can be gated on it.
  def begun?(now: Time.current) = starts_on.present? && now.in_time_zone(EARLIEST_ZONE).to_date >= starts_on

  def self.human_attribute_name(attribute, options = {})
    case attribute.to_s
    when "hp_seconds" then "Health"
    when "art_alt" then "Alt text"
    else super
    end
  end

  private

  # A boss week is always Friday to Thursday. `ends_on` is filled in from `starts_on` when it is left out.
  def default_ends_on
    self.ends_on ||= starts_on + 6 if starts_on
  end

  def week_is_friday_to_thursday
    return unless starts_on && ends_on

    errors.add(:starts_on, "must be a Friday") unless starts_on.friday?
    errors.add(:ends_on, "must be the Thursday six days after the start") unless ends_on == starts_on + 6
  end

  def ends_on_not_before_starts_on
    errors.add(:ends_on, "can't be before the start date") if starts_on && ends_on && ends_on < starts_on
  end

  def no_overlap
    return unless starts_on && ends_on && ends_on >= starts_on

    overlapping = Boss.where.not(id: id).where(starts_on: ..ends_on, ends_on: starts_on..)
    errors.add(:base, "These dates overlap another boss") if overlapping.exists?
  end

  def hp_fixed_once_started
    errors.add(:hp_seconds, "can't change once the boss has started") if hp_seconds_changed? && started?
  end

  def dates_fixed
    errors.add(:base, "A boss's dates can't be changed") if starts_on_changed? || ends_on_changed?
  end

  # A defeat is history: it cannot be cleared or moved, even if a correction later lowers the damage.
  def defeat_is_final
    errors.add(:defeated_at, "can't be changed once set") if defeated_at_changed? && defeated_at_was.present?
  end
end
