# One settled local day for one user (see Game::Settle): the day's raw coded seconds, whether it met the 15-minute and
# daily-goal thresholds, whether the freeze covered it, the streak state after it, and the bonus (basis points) it
# earns on approved hours. Immutable once written: a late hours entry for an already settled date does not change it.
class DailyResult < ApplicationRecord
  belongs_to :user

  validates :local_date, presence: true
  validates :raw_seconds, numericality: { only_integer: true, in: 0..86_400 }
  validates :streak_15, :goal_streak, :days_since_freeze, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :bonus_bps, numericality: { only_integer: true, in: 0..10_000 }
  validates :quick_met, :goal_met, :freeze_used, :freeze_available, inclusion: { in: [ true, false ] }

  scope :chronological, -> { order(:local_date) }

  def readonly? = !new_record? || super

  # `delete` skips callbacks and the read-only check, so refuse it too.
  def delete = raise(ActiveRecord::ReadOnlyRecord, "daily results are immutable")

  before_destroy { raise ActiveRecord::ReadOnlyRecord, "daily results are immutable" }

  # The streak state after this day, for settling the next one.
  def streak_state
    Game::StreakCalculator::State.new(streak_15: streak_15, goal_streak: goal_streak,
                                      freeze_available: freeze_available, days_since_freeze: days_since_freeze)
  end
end
