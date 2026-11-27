require "test_helper"

class Onboarding::DailyTimeTest < ActiveSupport::TestCase
  DT = Onboarding::DailyTime
  TODAY = Date.new(2026, 12, 1)

  test "with no end date the daily time counts against the stand-in length" do
    assert_equal 30, DT.card_days(today: TODAY, ends_on: nil)
    assert_equal 60, DT.minutes_a_day(30, today: TODAY, ends_on: nil) # 30 hours in 30 days
    assert_nil DT.minutes_a_day(300, today: TODAY, ends_on: nil) # over the biggest pace choice a day: total hours instead
    assert_nil DT.days_left(today: TODAY, ends_on: nil)
    assert DT.reachable?(30, 15, today: TODAY, ends_on: nil)
  end

  test "a past end date gives nothing and nothing is reachable" do
    assert_nil DT.minutes_a_day(5, today: TODAY, ends_on: Date.new(2026, 11, 30))
    assert_not DT.reachable?(5, 120, today: TODAY, ends_on: Date.new(2026, 11, 30))
  end

  test "today counts as a day and the result rounds up to a step" do
    ends = TODAY + 9 # ten days left, today included
    assert_equal 10, DT.days_left(today: TODAY, ends_on: ends)
    assert_equal 30, DT.minutes_a_day(1, today: TODAY, ends_on: ends)   # 6 min -> the smallest pace choice, 30
    assert_equal 30, DT.minutes_a_day(5, today: TODAY, ends_on: ends)   # 30 -> 30 (edge: exactly a choice)
    assert_equal 60, DT.minutes_a_day(5.1, today: TODAY, ends_on: ends) # 30.6 -> 60
    assert_equal 60, DT.minutes_a_day(10, today: TODAY, ends_on: ends)
    assert_equal 120, DT.minutes_a_day(15, today: TODAY, ends_on: ends) # 90 -> 120
    assert_equal 120, DT.minutes_a_day(16, today: TODAY, ends_on: ends) # 96 -> 120
    assert_equal 180, DT.minutes_a_day(30, today: TODAY, ends_on: ends)
  end

  test "more than the biggest pace choice a day falls back to nothing" do
    assert_equal 180, DT.minutes_a_day(30, today: TODAY, ends_on: TODAY + 9)
    assert_nil DT.minutes_a_day(31, today: TODAY, ends_on: TODAY + 9)
  end

  test "the wording" do
    assert_equal "about 30 minutes a day", DT.text(30)
    assert_equal "about 1 hour a day", DT.text(60)
    assert_equal "about 1.5 hours a day", DT.text(90)
    assert_equal "about 2 hours a day", DT.text(120)
    assert_nil DT.text(nil)
  end

  test "reachable compares the days a pace needs with the days left" do
    ends = TODAY + 9
    assert DT.reachable?(10, 60, today: TODAY, ends_on: ends)
    assert_not DT.reachable?(11, 60, today: TODAY, ends_on: ends)
  end

  test "the end date comes from the environment override, never from the committed config" do
    assert_nil Rails.application.config_for(:game).dig(:onboarding, :program_ends_on).presence
    ENV["ONBOARDING_PROGRAM_ENDS_ON"] = "2027-01-31"
    assert_equal Date.new(2027, 1, 31), DT.ends_on
  ensure
    ENV.delete("ONBOARDING_PROGRAM_ENDS_ON")
  end
end
