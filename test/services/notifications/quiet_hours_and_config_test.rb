require "test_helper"

class Notifications::QuietHoursAndConfigTest < ActiveSupport::TestCase
  PACIFIC = ActiveSupport::TimeZone["Pacific Time (US & Canada)"] # UTC-8 in November
  CONFIG = Notifications::Config.current

  def deferral(instant, zone: PACIFIC, config: CONFIG)
    Notifications::QuietHours.deferral(instant, zone, config: config)
  end

  test "defaults are 22:00 to 07:00" do
    assert_equal 22 * 60, CONFIG.quiet_start
    assert_equal 7 * 60, CONFIG.quiet_end
  end

  test "late evening is deferred to 07:00 the next local morning" do
    # 22:30 PST on Nov 9 is 06:30 UTC on Nov 10.
    assert_equal Time.utc(2026, 11, 10, 15, 0), deferral(Time.utc(2026, 11, 10, 6, 30))
    assert_equal Time.utc(2026, 11, 10, 15, 0), deferral(Time.utc(2026, 11, 10, 6, 0)) # exactly 22:00 PST
  end

  test "early morning is deferred to 07:00 the same local day" do
    assert_equal Time.utc(2026, 11, 10, 15, 0), deferral(Time.utc(2026, 11, 10, 12, 0)) # 04:00 PST
    assert_equal Time.utc(2026, 11, 10, 15, 0), deferral(Time.utc(2026, 11, 10, 8, 0)) # exactly midnight PST
  end

  test "outside the window nothing is deferred, including exactly 07:00 and just before 22:00" do
    assert_nil deferral(Time.utc(2026, 11, 10, 15, 0)) # 07:00 PST
    assert_nil deferral(Time.utc(2026, 11, 10, 20, 0)) # noon PST
    assert_nil deferral(Time.utc(2026, 11, 11, 5, 59)) # 21:59 PST
  end

  test "a window that does not cross midnight works" do
    config = CONFIG.with(quiet_start: 13 * 60, quiet_end: 14 * 60)
    assert_equal Time.utc(2026, 11, 10, 22, 0), deferral(Time.utc(2026, 11, 10, 21, 30), config: config) # 13:30 PST
    assert_nil deferral(Time.utc(2026, 11, 10, 22, 0), config: config)
  end

  test "equal bounds turn quiet hours off" do
    assert_nil deferral(Time.utc(2026, 11, 10, 8, 0), config: CONFIG.with(quiet_start: 0, quiet_end: 0))
  end

  test "the end of the window follows daylight saving" do
    # 2027-03-14: New York springs forward at 02:00. 03:00 EDT is inside quiet hours, 07:00 EDT is 11:00 UTC.
    new_york = ActiveSupport::TimeZone["Eastern Time (US & Canada)"]
    assert_equal Time.utc(2027, 3, 14, 11, 0), deferral(Time.utc(2027, 3, 14, 7, 30), zone: new_york)
  end

  test "config is loaded from config/notifications.yml and clamped" do
    assert_operator CONFIG.max_attempts, :<=, Notification::MAX_ATTEMPTS
    assert_operator CONFIG.backoff_base, :>, 0
    base = Rails.application.config_for(:notifications)
    assert_equal Notification::MAX_ATTEMPTS, Notifications::Config.from_hash(base.merge(max_attempts: 99)).max_attempts
    assert_equal 1, Notifications::Config.from_hash(base.merge(max_attempts: 0)).max_attempts
    assert_raises(ArgumentError) { Notifications::Config.from_hash(base.merge(quiet_hours_start: "25:00")) }
    assert_raises(KeyError) { Notifications::Config.from_hash(base.except(:templates)) }
  end

  test "backoff doubles and is capped" do
    config = CONFIG.with(backoff_base: 60, backoff_max: 500)
    assert_equal [ 60, 120, 240, 480, 500, 500 ], (1..6).map { |attempts| config.backoff_seconds(attempts) }
    assert_equal 60, config.backoff_seconds(0)
  end

  test "message copy is spelled Hack Club, short, and makes no prize promises" do
    text = CONFIG.template("daily_reminder")
    assert_includes text, "Hack Club"
    assert_no_match(/hackclub/i, text)
    assert_no_match(/\bprizes?\b|\bwin\b|\bfree\b/i, text)
    assert_operator text.length, :<=, 300
    assert_raises(KeyError) { CONFIG.template("unknown_kind") }
  end
end
