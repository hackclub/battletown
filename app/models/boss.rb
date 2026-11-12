# The weekly community boss. One row per week, Friday to Thursday, with its health in seconds of coded time.
# Damage is never stored: it is the sum of the hours ledger over the boss's local dates (Bosses::Damage).
# `defeated_at` is set once by Bosses::CheckDefeat and is never cleared. A boss is not about a person.
class Boss < ApplicationRecord
  # Same-origin illustration slots: each key is an image at app/assets/images/bosses/<key>.webp, with its alt text.
  ARTS = {
    "placeholder" => "A tall armoured boss in a white cat-eared helmet, holding a huge spiked blade"
  }.freeze
  ART_KEYS = ARTS.keys.freeze
  NAME_LENGTH = 1..60
  # The most health a boss can have (100,000 hours); keeps the integer column far from overflow.
  MAX_HP_SECONDS = 360_000_000
  # A boss counts as started once its first day has begun in the earliest time zone on Earth (UTC+14), so an
  # HP edit can never move anybody's bar once anybody could have started hitting it. Any hours already on its dates
  # start it too: Hours::Credit accepts a user's tomorrow, which in UTC+14 is a date no zone has reached yet.
  EARLIEST_ZONE = "Pacific/Kiritimati".freeze

  scope :covering, ->(date) { where(starts_on: ..date, ends_on: date..) }
  scope :chronological, -> { order(:starts_on) }

  normalizes :name, with: ->(name) { name.to_s.squish }

  validates :name, length: { in: NAME_LENGTH }
  validates :art_key, inclusion: { in: ART_KEYS }
  validates :starts_on, :ends_on, presence: true
  validates :starts_on, uniqueness: true
  validates :hp_seconds, numericality: { only_integer: true, in: 1..MAX_HP_SECONDS }
  validate :ends_on_not_before_starts_on
  validate :no_overlap
  validate :hp_fixed_once_started, on: :update
  validate :dates_fixed, on: :update
  validate :defeat_is_final, on: :update

  def art_path = "bosses/#{art_key}.webp"

  def range = starts_on..ends_on

  def defeated? = defeated_at.present?

  # Whole hours, or a decimal (two places) when the health is not a whole number of hours.
  def hp_hours
    return if hp_seconds.nil?

    (hp_seconds % 3600).zero? ? hp_seconds / 3600 : (hp_seconds / 3600.0).round(2)
  end

  # Admins enter hours; anything that is not a number leaves the health blank so validation reports it.
  def hp_hours=(value)
    self.hp_seconds = (BigDecimal(value.to_s.strip) * 3600).round
  rescue ArgumentError, FloatDomainError
    self.hp_seconds = nil
  end

  def started?(now: Time.current)
    return false if starts_on.nil?

    now.in_time_zone(EARLIEST_ZONE).to_date >= starts_on || (ends_on.present? && HourEntry.exists?(local_date: range))
  end

  def self.human_attribute_name(attribute, options = {})
    attribute.to_s == "hp_seconds" ? "Health" : super
  end

  private

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
