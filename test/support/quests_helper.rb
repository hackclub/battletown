require_relative "bosses_helper"

# Helpers for the quest tests. The week is the first launch boss week (Friday 2026-11-13 to Thursday 2026-11-19); tests
# that create quests freeze the clock inside it with `travel_to QuestsHelper::NOW` so nothing depends on the real date.
module QuestsHelper
  include BossesHelper

  WEEK_START = BossesHelper::FRIDAY
  WEEK_END = BossesHelper::THURSDAY
  NOW = Time.utc(2026, 11, 16, 12)

  # A quest for the week starting `starts_on` (its boss is made when missing).
  def make_quest(starts_on: WEEK_START, goal_key: "code_days", target: 3, reward_coins: 15)
    Boss.find_by(starts_on: starts_on) || make_boss(starts_on: starts_on)
    quest = Quest.new(starts_on: starts_on, goal_key: goal_key, reward_coins: reward_coins)
    quest.target = target if target
    quest.save!
    quest
  end

  # A signed-up, onboarded user whose sign-up date is before the quest week.
  def quest_user(time_zone: "UTC", created_on: Date.new(2026, 11, 1))
    user = User.create!(hca_uid: "ident!quest-#{SecureRandom.hex(6)}", created_at: Time.utc(created_on.year, created_on.month, created_on.day, 12))
    user.update_columns(time_zone: time_zone, signed_up_on: Hours::Days.local_date(user.created_at, time_zone), onboarded_at: user.created_at + 1.hour, onboarding_step: 4)
    user
  end

  # One ledger row of coded time, recorded at a chosen instant (HourEntry#recorded_at is when it reached the ledger).
  def code_at(user, date, seconds, recorded_at: nil)
    entry = HourEntry.create!(user: user, local_date: date, seconds: seconds, source: "manual", note: "test", idempotency_key: SecureRandom.hex(8))
    HourEntry.where(id: entry.id).update_all(recorded_at: recorded_at) if recorded_at
    entry
  end
end
