require "test_helper"

class Game::DaysTest < ActiveSupport::TestCase
  GRACE = 6 * 3600

  def settles(date, zone) = Game::Days.settles_at(date, zone, grace_seconds: GRACE)

  test "local_date follows the zone, not UTC" do
    instant = Time.utc(2026, 11, 12, 3, 0, 0)
    assert_equal Date.new(2026, 11, 12), Game::Days.local_date(instant, "UTC")
    assert_equal Date.new(2026, 11, 11), Game::Days.local_date(instant, "America/New_York")
    assert_equal Date.new(2026, 11, 12), Game::Days.local_date(instant, "Asia/Kolkata")
  end

  test "the same instant is three different dates at +14, -11 and UTC" do
    instant = Time.utc(2026, 6, 15, 12, 0, 0)
    assert_equal Date.new(2026, 6, 16), Game::Days.local_date(instant, "Pacific/Kiritimati")
    assert_equal Date.new(2026, 6, 15), Game::Days.local_date(instant, "UTC")
    assert_equal Date.new(2026, 6, 15), Game::Days.local_date(instant, "Pacific/Pago_Pago")
    assert_equal Date.new(2026, 6, 14), Game::Days.local_date(Time.utc(2026, 6, 15, 10, 59, 59), "Pacific/Pago_Pago")
  end

  test "half and three-quarter hour offsets" do
    assert_equal Date.new(2026, 3, 2), Game::Days.local_date(Time.utc(2026, 3, 1, 18, 30, 0), "Asia/Kolkata")
    assert_equal Date.new(2026, 3, 1), Game::Days.local_date(Time.utc(2026, 3, 1, 18, 29, 59), "Asia/Kolkata")
    assert_equal Date.new(2026, 3, 2), Game::Days.local_date(Time.utc(2026, 3, 1, 18, 15, 0), "Asia/Kathmandu")
    assert_equal Date.new(2026, 3, 1), Game::Days.local_date(Time.utc(2026, 3, 1, 18, 14, 59), "Asia/Kathmandu")
  end

  test "23:59:59 and 00:00:00 local land on different dates" do
    assert_equal Date.new(2026, 11, 10), Game::Days.local_date(Time.utc(2026, 11, 11, 4, 59, 59), "America/New_York")
    assert_equal Date.new(2026, 11, 11), Game::Days.local_date(Time.utc(2026, 11, 11, 5, 0, 0), "America/New_York")
  end

  test "nil, blank, invalid and non-string zones fall back to UTC" do
    instant = Time.utc(2026, 11, 12, 23, 30, 0)
    [ nil, "", "  ", "Not/AZone", 3, :utc ].each do |bad|
      assert_equal "UTC", Game::Days.zone(bad).name, bad.inspect
      assert_equal Date.new(2026, 11, 12), Game::Days.local_date(instant, bad)
    end
    assert_equal Time.utc(2026, 11, 13, 6, 0, 0), settles(Date.new(2026, 11, 12), nil)
  end

  test "Rails zone names work as well as IANA ids" do
    assert_equal settles(Date.new(2026, 11, 12), "America/New_York"), settles(Date.new(2026, 11, 12), "Eastern Time (US & Canada)")
  end

  test "settles_at is local midnight at the end of the date plus the grace" do
    assert_equal Time.utc(2026, 11, 13, 6, 0, 0), settles(Date.new(2026, 11, 12), "UTC")
    assert_equal Time.utc(2026, 11, 13, 11, 0, 0), settles(Date.new(2026, 11, 12), "America/New_York")
    # Kolkata (+5:30): local midnight starting 2026-11-13 is 2026-11-12 18:30 UTC, plus 6h.
    assert_equal Time.utc(2026, 11, 13, 0, 30, 0), settles(Date.new(2026, 11, 12), "Asia/Kolkata")
    # Kathmandu (+5:45).
    assert_equal Time.utc(2026, 11, 13, 0, 15, 0), settles(Date.new(2026, 11, 12), "Asia/Kathmandu")
    # Kiritimati (+14) and Pago Pago (-11).
    assert_equal Time.utc(2026, 11, 12, 16, 0, 0), settles(Date.new(2026, 11, 12), "Pacific/Kiritimati")
    assert_equal Time.utc(2026, 11, 13, 17, 0, 0), settles(Date.new(2026, 11, 12), "Pacific/Pago_Pago")
  end

  test "settles_at uses calendar maths on the 25 hour fall-back day (America/New_York 2026-11-01)" do
    # Nov 1 has 25 hours. The end of Nov 1 is midnight EST (05:00 UTC Nov 2), not 24 hours after midnight EDT.
    assert_equal Time.utc(2026, 11, 2, 11, 0, 0), settles(Date.new(2026, 11, 1), "America/New_York")
    assert_not_equal Time.utc(2026, 11, 1, 4, 0, 0) + 24.hours + GRACE, settles(Date.new(2026, 11, 1), "America/New_York")
    # The day before it ends at midnight EDT (04:00 UTC Nov 1).
    assert_equal Time.utc(2026, 11, 1, 10, 0, 0), settles(Date.new(2026, 10, 31), "America/New_York")
  end

  test "settles_at on the 23 hour spring-forward day (America/New_York 2027-03-14)" do
    # Mar 14 2027 starts at midnight EST (05:00 UTC) and ends at midnight EDT (04:00 UTC Mar 15).
    assert_equal Time.utc(2027, 3, 15, 10, 0, 0), settles(Date.new(2027, 3, 14), "America/New_York")
    assert_equal Time.utc(2027, 3, 14, 11, 0, 0), settles(Date.new(2027, 3, 13), "America/New_York")
  end

  test "local_date around the fall-back repeated hour" do
    # 05:30Z and 06:30Z are 01:30 EDT and 01:30 EST: both Nov 1.
    assert_equal Date.new(2026, 11, 1), Game::Days.local_date(Time.utc(2026, 11, 1, 4, 30, 0), "America/New_York")
    assert_equal Date.new(2026, 11, 1), Game::Days.local_date(Time.utc(2026, 11, 1, 5, 30, 0), "America/New_York")
    assert_equal Date.new(2026, 11, 1), Game::Days.local_date(Time.utc(2026, 11, 1, 6, 30, 0), "America/New_York")
    assert_equal Date.new(2026, 10, 31), Game::Days.local_date(Time.utc(2026, 11, 1, 3, 59, 59), "America/New_York")
    assert_equal Date.new(2026, 11, 2), Game::Days.local_date(Time.utc(2026, 11, 2, 5, 0, 0), "America/New_York")
  end

  test "a midnight that does not exist still resolves to a valid instant" do
    # Sao Paulo skipped midnight on 2018-11-04 (clocks went from 00:00 to 01:00).
    instant = Game::Days.settles_at(Date.new(2018, 11, 3), "America/Sao_Paulo", grace_seconds: 0)
    assert_equal Time.utc(2018, 11, 4, 3, 0, 0), instant
  end

  test "settled? flips exactly at the settle instant" do
    date = Date.new(2026, 11, 12)
    at = settles(date, "America/New_York")
    assert_not Game::Days.settled?(date, "America/New_York", at - 1, grace_seconds: GRACE)
    assert Game::Days.settled?(date, "America/New_York", at, grace_seconds: GRACE)
  end

  test "last_settled_date is yesterday only after the grace has passed" do
    zone = "America/New_York"
    just_before = Time.utc(2026, 11, 12, 10, 59, 59) # 05:59:59 EST on Nov 12
    just_after = Time.utc(2026, 11, 12, 11, 0, 0)
    assert_equal Date.new(2026, 11, 10), Game::Days.last_settled_date(just_before, zone, grace_seconds: GRACE)
    assert_equal Date.new(2026, 11, 11), Game::Days.last_settled_date(just_after, zone, grace_seconds: GRACE)
  end

  test "last_settled_date with no grace is yesterday" do
    assert_equal Date.new(2026, 11, 11), Game::Days.last_settled_date(Time.utc(2026, 11, 12, 0, 0, 0), "UTC", grace_seconds: 0)
  end
end
