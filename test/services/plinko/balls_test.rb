require "test_helper"
require_relative "../../support/plinko_helper"

class PlinkoBallsTest < ActiveSupport::TestCase
  include PlinkoHelper

  D1 = Date.new(2026, 11, 9)

  setup do
    @config = Plinko::Config.current # 5 minutes a ball, bank of 20, 7 days
    @user = users(:onboarded)
  end

  def compute(seconds: {}, drops: {}, today: D1)
    Plinko::Balls.compute(daily_seconds: seconds, drops_by_date: drops, today: today, config: @config)
  end

  test "nothing coded means no balls and a full ball to wait for" do
    result = compute
    assert_equal 0, result.available
    assert_equal 300, result.seconds_to_next
    assert_not result.any?
  end

  test "the boundary is exactly five counted minutes" do
    assert_equal 0, compute(seconds: { D1 => 299 }).available
    assert_equal 1, compute(seconds: { D1 => 300 }).available
    assert_equal 1, compute(seconds: { D1 => 599 }).available
    assert_equal 2, compute(seconds: { D1 => 600 }).available
    assert_equal 1, compute(seconds: { D1 => 299 }).seconds_to_next
    assert_equal 300, compute(seconds: { D1 => 300 }).seconds_to_next
  end

  test "leftover minutes carry over to the next day" do
    result = compute(seconds: { D1 => 180, D1 + 1 => 120 }, today: D1 + 1)
    assert_equal 1, result.available
    assert_equal 1, result.earned_total
  end

  test "dropped balls are taken off, oldest first" do
    result = compute(seconds: { D1 => 1500 }, drops: { D1 => 2 })
    assert_equal 3, result.available
    assert_equal 5, result.earned_total
    assert_equal 2, result.dropped_total
  end

  test "a ball is usable on the day it is earned and the six days after, then it expires" do
    seconds = { D1 => 300 }
    assert_equal 1, compute(seconds: seconds, today: D1 + 6).available
    assert_equal 0, compute(seconds: seconds, today: D1 + 7).available
    assert_equal D1 + 6, compute(seconds: seconds, today: D1 + 3).last_usable_on
  end

  test "drops use the oldest ball, so a newer one outlives it" do
    seconds = { D1 => 300, D1 + 2 => 300 } # ball A on day 0, ball B on day 2
    result = compute(seconds: seconds, drops: { D1 + 3 => 1 }, today: D1 + 7)
    assert_equal 1, result.available, "A was dropped on day 3; B is good until day 8 (A would have expired on day 7)"
    assert_equal 0, compute(seconds: seconds, today: D1 + 9).available
  end

  test "the bank holds at most 20 balls and the oldest are pushed out" do
    one_day = compute(seconds: { D1 => 30 * 300 })
    assert_equal 20, one_day.available
    assert one_day.full
    assert_equal 30, one_day.earned_total

    spread = compute(seconds: { D1 => 15 * 300, D1 + 1 => 10 * 300 }, today: D1 + 1)
    assert_equal 20, spread.available
    assert_equal D1 + 6, spread.last_usable_on, "5 of day 0's 15 balls were pushed out; the oldest left is still from day 0"
  end

  test "balls played before the cap bites are not lost" do
    result = compute(seconds: { D1 => 25 * 300 }, drops: { D1 => 25 })
    assert_equal 0, result.available
  end

  test "a drop dated after today (a player who moved west) is never undone" do
    result = compute(seconds: { D1 => 300 }, drops: { D1 + 1 => 1 }, today: D1)
    assert_equal 0, result.available
  end

  test "reads the ledger and the drops for a user, in the user's own zone" do
    code_on(@user, D1, minutes(10))
    code_on(@user, D1 + 1, minutes(3))
    dropped_on(@user, D1 + 1)
    now = Time.utc(2026, 11, 10, 12)
    result = balls_for(@user, now)
    assert_equal 2, result.earned_total
    assert_equal 1, result.available
  end

  test "expiry is decided on the player's local date, so zones differ at the edge" do
    code_on(@user, D1, minutes(5))
    just_before = Time.utc(2026, 11, 15, 23, 30) # 15 Nov in UTC, 16 Nov in Auckland, 15 Nov in Los Angeles
    @user.update_columns(time_zone: "UTC")
    assert_equal 1, balls_for(@user, just_before).available
    @user.update_columns(time_zone: "Pacific/Auckland") # local date 16 Nov = day 7: expired
    assert_equal 0, balls_for(@user, just_before).available
    @user.update_columns(time_zone: "America/Los_Angeles") # 15 Nov = day 6: still good
    assert_equal 1, balls_for(@user, just_before).available
  end

  test "time before the sign-up date earns nothing" do
    @user.update_columns(signed_up_on: D1, created_at: D1.in_time_zone("UTC"))
    code_on(@user, D1 - 1, minutes(60))
    code_on(@user, D1, minutes(5))
    assert_equal 1, balls_for(@user, Time.utc(2026, 11, 9, 20)).available
  end

  test "earning_starts_on leaves out earlier time" do
    code_on(@user, D1, minutes(10))
    code_on(@user, D1 + 1, minutes(5))
    later = Plinko::Config.current.with(earning_starts_on: D1 + 1)
    assert_equal 1, Plinko::Balls.for(@user, now: Time.utc(2026, 11, 10, 20), config: later).available
    assert_equal 3, Plinko::Balls.for(@user, now: Time.utc(2026, 11, 10, 20)).available
  end

  test "a correction to the ledger shows at once" do
    code_on(@user, D1, minutes(10))
    HourEntry.create!(user: @user, local_date: D1, seconds: -minutes(5), source: "adjustment", note: "fix", idempotency_key: SecureRandom.hex(8))
    assert_equal 1, balls_for(@user, Time.utc(2026, 11, 9, 20)).available
  end
end
