require "test_helper"

class Hours::CreditTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 11, 11, 12, 0, 0)

  setup do
    @user = users(:onboarded)
    travel_to NOW
  end

  teardown { travel_back }

  def credit(**args)
    Hours::Credit.call(**{ user: @user, seconds: 1_800, source: "manual", note: "Test", idempotency_key: "k#{SecureRandom.hex(4)}",
                           local_date: Date.new(2026, 11, 11) }.merge(args))
  end

  def zone!(name) = @user.update_column(:time_zone, name)

  test "credits a row with the date frozen on it" do
    result = credit(hackatime_project: "my-game", created_by: "rake:credit")

    assert_predicate result, :created?
    assert_equal 1_800, result.credited_seconds
    entry = result.entry
    assert_equal Date.new(2026, 11, 11), entry.local_date
    assert_equal "my-game", entry.hackatime_project
    assert_equal "rake:credit", entry.created_by
    assert_not_nil entry.recorded_at
  end

  test "the same idempotency key returns the existing row and writes nothing" do
    first = credit(idempotency_key: "once", seconds: 600)
    again = credit(idempotency_key: "once", seconds: 9_999, local_date: Date.new(2026, 11, 10), note: "different")

    assert_predicate again, :duplicate?
    assert_equal first.entry.id, again.entry.id
    assert_equal 0, again.credited_seconds
    assert_equal 1, HourEntry.where(user: @user, idempotency_key: "once").count
    assert_equal 600, Hours::Totals.seconds_for_date(@user, Date.new(2026, 11, 11))
  end

  test "an old key still answers as a duplicate after the backfill window has passed" do
    credit(idempotency_key: "old", local_date: Date.new(2026, 11, 9))
    travel_to NOW + 10.days
    assert_predicate credit(idempotency_key: "old", local_date: Date.new(2026, 11, 9)), :duplicate?
  end

  test "keys are per user" do
    credit(idempotency_key: "shared")
    assert_predicate credit(user: users(:new_user), idempotency_key: "shared"), :created?
  end

  test "positive credits are clamped so the day never passes the daily cap" do
    assert_equal 43_200, Hours::Config.current.daily_cap_seconds
    credit(seconds: 40_000)

    clamped = credit(seconds: 10_000)
    assert_predicate clamped, :clamped?
    assert_predicate clamped, :created?
    assert_equal 3_200, clamped.credited_seconds
    assert_equal 10_000, clamped.requested_seconds

    full = credit(seconds: 60)
    assert_predicate full, :capped?
    assert_nil full.entry
    assert_equal 0, full.credited_seconds
    assert_equal 43_200, Hours::Totals.seconds_for_date(@user, Date.new(2026, 11, 11))
  end

  test "the cap is per local date and per user" do
    credit(seconds: 43_200)
    assert_predicate credit(seconds: 600, local_date: Date.new(2026, 11, 10)), :created?
    assert_predicate credit(seconds: 600, user: users(:new_user)), :created?
  end

  test "a negative adjustment frees room under the cap" do
    credit(seconds: 43_200)
    credit(seconds: -3_600, source: "adjustment", note: "Idle time")

    result = credit(seconds: 7_200)
    assert_equal 3_600, result.credited_seconds
    assert_equal 43_200, Hours::Totals.seconds_for_date(@user, Date.new(2026, 11, 11))
  end

  test "adjustments are never clamped and may be negative" do
    credit(seconds: 43_200)
    assert_equal 600, credit(seconds: 600, source: "adjustment", note: "Restore").credited_seconds
    assert_equal(-600, credit(seconds: -600, source: "adjustment", note: "Undo").entry.seconds)
  end

  test "a custom cap from config is honoured" do
    config = Hours::Config.new(daily_cap_seconds: 1_000, max_backfill_days: 3, active_seconds: 900)
    assert_equal 1_000, credit(seconds: 5_000, config: config).credited_seconds
    assert_predicate credit(seconds: 5_000, config: config), :capped?
  end

  test "rejects dates older than three days unless the source is an adjustment" do
    assert_predicate credit(local_date: Date.new(2026, 11, 8)), :created?
    assert_raises(Hours::Credit::Rejected) { credit(local_date: Date.new(2026, 11, 7)) }
    assert_equal 600, credit(local_date: Date.new(2026, 11, 7), seconds: 600, source: "adjustment", note: "Late fix").credited_seconds
    assert_raises(Hours::Credit::Rejected) { credit(local_date: Date.new(2026, 11, 7), source: "hackatime", note: nil) }
  end

  test "the window follows the user's local today" do
    zone!("Pacific/Kiritimati") # UTC+14: it is already 2026-11-12 there
    assert_predicate credit(local_date: Date.new(2026, 11, 9)), :created?
    assert_raises(Hours::Credit::Rejected) { credit(local_date: Date.new(2026, 11, 8)) }

    zone!("Pacific/Pago_Pago") # UTC-11: still 2026-11-11 01:00
    assert_predicate credit(local_date: Date.new(2026, 11, 8)), :created?
  end

  test "rejects a date later than the user's local tomorrow" do
    assert_predicate credit(local_date: Date.new(2026, 11, 12)), :created?
    assert_raises(Hours::Credit::Rejected) { credit(local_date: Date.new(2026, 11, 13)) }
  end

  test "rejects input that can never be credited" do
    assert_raises(Hours::Credit::Rejected) { credit(seconds: 0) }
    assert_raises(Hours::Credit::Rejected) { credit(seconds: -5) }
    assert_raises(Hours::Credit::Rejected) { credit(seconds: 86_401) }
    assert_raises(Hours::Credit::Rejected) { credit(seconds: 1.5) }
    assert_raises(Hours::Credit::Rejected) { credit(seconds: "60") }
    assert_raises(Hours::Credit::Rejected) { credit(source: "bonus") }
    assert_raises(Hours::Credit::Rejected) { credit(note: nil) }
    assert_raises(Hours::Credit::Rejected) { credit(idempotency_key: "") }
    assert_raises(Hours::Credit::Rejected) { credit(idempotency_key: "k" * 121) }
    assert_raises(Hours::Credit::Rejected) { credit(local_date: nil) }
    assert_raises(Hours::Credit::Rejected) { credit(at: NOW) }
    assert_raises(Hours::Credit::Rejected) { credit(local_date: "2026-11-11") }
    assert_raises(Hours::Credit::Rejected) { credit(user: User.new) }
    assert_equal 0, HourEntry.count
  end

  test "hackatime rows need no note" do
    assert_predicate credit(source: "hackatime", note: nil, hackatime_project: "p"), :created?
  end

  # --- local date from an instant ---

  def date_for(instant, zone)
    zone!(zone)
    credit(local_date: nil, at: instant, idempotency_key: "at-#{SecureRandom.hex(4)}", seconds: 60).entry.local_date
  end

  test "an instant becomes the user's local date, with UTC as the fallback" do
    instant = Time.utc(2026, 11, 11, 3, 30)
    assert_equal Date.new(2026, 11, 11), date_for(instant, nil)
    assert_equal Date.new(2026, 11, 11), date_for(instant, "")
    assert_equal Date.new(2026, 11, 11), date_for(instant, "Mars/Olympus_Mons")
    assert_equal Date.new(2026, 11, 10), date_for(instant, "Eastern Time (US & Canada)")
    assert_equal Date.new(2026, 11, 10), date_for(instant, "America/New_York")
  end

  test "far time zones put the same instant on different dates" do
    instant = Time.utc(2026, 11, 10, 11, 0)
    assert_equal Date.new(2026, 11, 11), date_for(instant, "Pacific/Kiritimati")
    assert_equal Date.new(2026, 11, 10), date_for(instant, "Pacific/Pago_Pago")
    assert_equal Date.new(2026, 11, 10), date_for(instant, "Asia/Kolkata")
    assert_equal Date.new(2026, 11, 10), date_for(instant, "Asia/Kathmandu")
  end

  test "half and quarter hour offsets flip at the right second" do
    assert_equal Date.new(2026, 11, 10), date_for(Time.utc(2026, 11, 10, 18, 29, 59), "Asia/Kolkata")
    assert_equal Date.new(2026, 11, 11), date_for(Time.utc(2026, 11, 10, 18, 30, 0), "Asia/Kolkata")
    assert_equal Date.new(2026, 11, 10), date_for(Time.utc(2026, 11, 10, 18, 14, 59), "Asia/Kathmandu")
    assert_equal Date.new(2026, 11, 11), date_for(Time.utc(2026, 11, 10, 18, 15, 0), "Asia/Kathmandu")
  end

  test "the clocks going back (25 hour day, 2026-11-01 in New York)" do
    travel_to Time.utc(2026, 11, 2, 12)
    {
      Time.utc(2026, 11, 1, 3, 59, 59) => Date.new(2026, 10, 31), # 23:59:59 EDT
      Time.utc(2026, 11, 1, 4, 0, 0) => Date.new(2026, 11, 1),    # 00:00 EDT
      Time.utc(2026, 11, 1, 5, 30, 0) => Date.new(2026, 11, 1),   # 01:30 EDT
      Time.utc(2026, 11, 1, 6, 30, 0) => Date.new(2026, 11, 1),   # 01:30 EST, the repeated hour
      Time.utc(2026, 11, 2, 4, 59, 59) => Date.new(2026, 11, 1),  # 23:59:59 EST, 25 hours after midnight
      Time.utc(2026, 11, 2, 5, 0, 0) => Date.new(2026, 11, 2)     # 00:00 EST
    }.each { |instant, expected| assert_equal expected, date_for(instant, "America/New_York"), instant.iso8601 }
  end

  test "the clocks going forward (23 hour day, 2027-03-14 in New York)" do
    travel_to Time.utc(2027, 3, 15, 12)
    {
      Time.utc(2027, 3, 14, 4, 59, 59) => Date.new(2027, 3, 13), # 23:59:59 EST
      Time.utc(2027, 3, 14, 5, 0, 0) => Date.new(2027, 3, 14),   # 00:00 EST
      Time.utc(2027, 3, 14, 7, 30, 0) => Date.new(2027, 3, 14),  # 03:30 EDT (02:30 does not exist)
      Time.utc(2027, 3, 15, 3, 59, 59) => Date.new(2027, 3, 14), # 23:59:59 EDT, 23 hours after midnight
      Time.utc(2027, 3, 15, 4, 0, 0) => Date.new(2027, 3, 15)    # 00:00 EDT
    }.each { |instant, expected| assert_equal expected, date_for(instant, "America/New_York"), instant.iso8601 }
  end

  test "an instant may be a TimeWithZone, a Time with an offset or a DateTime" do
    zone!("Asia/Kolkata")
    [ Time.utc(2026, 11, 10, 20, 0).in_time_zone("Pacific/Pago_Pago"), Time.new(2026, 11, 10, 9, 0, 0, "-11:00"), DateTime.new(2026, 11, 10, 20, 0, 0) ].each do |instant|
      assert_equal Date.new(2026, 11, 11), date_for(instant, "Asia/Kolkata"), instant.class.name
    end
  end

  test "the stored date does not move when the user later changes zone" do
    entry = credit(local_date: nil, at: Time.utc(2026, 11, 10, 23, 0), idempotency_key: "frozen").entry
    zone!("Pacific/Kiritimati")
    assert_equal Date.new(2026, 11, 10), entry.reload.local_date
  end
end
