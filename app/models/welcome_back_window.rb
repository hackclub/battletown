# One welcome-back window of the returning-user bonus (feature flag `returning`, see Game::ReturningBoost): the first
# counted day back after an idle stretch (`starts_on`) through `ends_on`, inclusive, as the user's own local dates.
# While a settled day falls inside it, its streak bonus is at least the configured floor. Written once per idle period by
# Game::Settle; deleted with the user. Holds dates and a count, nothing personal.
class WelcomeBackWindow < ApplicationRecord
  belongs_to :user

  validates :starts_on, :ends_on, presence: true
  validates :idle_days, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :starts_on, uniqueness: { scope: :user_id }
  validate :ends_on_not_before_starts_on

  scope :covering, ->(date) { where(starts_on: ..date, ends_on: date..) }

  def dates = (starts_on..ends_on)

  private

  def ends_on_not_before_starts_on
    errors.add(:ends_on, "must not be before the start") if starts_on && ends_on && ends_on < starts_on
  end
end
