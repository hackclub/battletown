require "test_helper"
require_relative "coins_helper"
require_relative "bosses_helper"

# Builders for the weekly merch track tests. The boss week is the one BossesHelper uses (Friday 13 to Thursday 19 November
# 2026), so nothing depends on the clock.
module MerchHelper
  include CoinsHelper
  include BossesHelper

  WEEK_START = BossesHelper::FRIDAY
  WEEK_END = BossesHelper::THURSDAY
  # Noon UTC the day after the week: every day of the week is settled for a user in UTC.
  AFTER_WEEK = Time.utc(2026, 11, 20, 12)

  # One settled day (what Game::Settle would write) with the goal met or not. `frozen` is a day the freeze covered.
  def goal_day(user, date, met: true, frozen: false)
    DailyResult.create!(user: user, local_date: date, raw_seconds: met ? 3600 : 0, quick_met: met && !frozen, goal_met: met,
                        freeze_used: frozen, streak_15: frozen ? 3 : 0, goal_streak: 0, freeze_available: !frozen)
  end

  # Settled goal days on the first `count` dates of the week.
  def goal_days(user, count, from: WEEK_START)
    count.times { |offset| goal_day(user, from + offset) }
  end

  def verified!(user)
    user.update_columns(verification_status: "verified")
    user
  end

  # An approved ship, written straight to the table (the ship flow has its own tests).
  def approved_ship!(user)
    project = Project.create!(user: user, name: "Merch project #{SecureRandom.hex(3)}", kind: "game")
    Ship.create!(user: user, project: project, status: "approved", description: "Built it.", repo_url: "https://github.com/octo/merch-#{SecureRandom.hex(3)}",
                 coded_seconds: 3600, approved_seconds: 3600, window_start_date: Date.new(2026, 11, 9), window_end_date: Date.new(2026, 11, 9),
                 daily_seconds: { "2026-11-09" => 3600 }, submitted_at: Time.utc(2026, 11, 10), reviewed_at: Time.utc(2026, 11, 10, 1))
  end

  # A user who has everything needed to claim the first week: five goal days, verified, one approved ship.
  def claimant(goal_count: 5)
    user = verified!(build_user(created_on: Date.new(2026, 11, 1)))
    goal_days(user, goal_count)
    approved_ship!(user)
    user
  end

  def config(**changes) = MerchTrack::Config.current.with(**changes)
end
