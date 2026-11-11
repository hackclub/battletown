require "test_helper"

class Notifications::RemindersTest < ActiveSupport::TestCase
  Schedule = Struct.new(:coding_days, :coding_time, :time_zone)

  NEW_YORK = "Eastern Time (US & Canada)".freeze
  MON = 1
  WED = 4
  SUN = 64
  ALL = 127

  def due(days, time, zone, after)
    Notifications::Reminders.due_at(Schedule.new(days, time, zone), after: after)
  end

  def utc(*parts) = Time.utc(*parts)

  test "next coding day at the local wall-clock time" do
    # Monday 2026-11-09 18:30 EST is 23:30 UTC.
    assert_equal utc(2026, 11, 9, 23, 30), due(MON, "18:30", NEW_YORK, utc(2026, 11, 8, 12))
  end

  test "returns nil rather than guessing when the schedule is incomplete or invalid" do
    after = utc(2026, 11, 9)
    assert_nil due(0, "18:30", NEW_YORK, after)
    assert_nil due(nil, "18:30", NEW_YORK, after)
    assert_nil due(128, "18:30", NEW_YORK, after)
    assert_nil due(-1, "18:30", NEW_YORK, after)
    assert_nil due("5", "18:30", NEW_YORK, after)
    assert_nil due(ALL, nil, NEW_YORK, after)
    assert_nil due(ALL, "", NEW_YORK, after)
    assert_nil due(ALL, "24:00", NEW_YORK, after)
    assert_nil due(ALL, "9:00", NEW_YORK, after)
    assert_nil due(ALL, "18:30", nil, after)
    assert_nil due(ALL, "18:30", "", after)
    assert_nil due(ALL, "18:30", "Mars/Phobos", after)
    assert_nil due(ALL, "18:30", 5, after)
  end

  test "after exactly equal to the due instant is strictly excluded" do
    exact = utc(2026, 11, 9, 23, 30)
    assert_equal utc(2026, 11, 16, 23, 30), due(MON, "18:30", NEW_YORK, exact)
    assert_equal exact, due(MON, "18:30", NEW_YORK, exact - 1)
    assert_equal utc(2026, 11, 10, 23, 30), due(ALL, "18:30", NEW_YORK, exact)
  end

  test "all days versus a single day" do
    after = utc(2026, 11, 9, 23, 30) # Monday's reminder instant
    assert_equal utc(2026, 11, 10, 23, 30), due(ALL, "18:30", NEW_YORK, after)
    assert_equal utc(2026, 11, 11, 23, 30), due(WED, "18:30", NEW_YORK, after)
  end

  test "week wrap-around from Sunday to Monday and Sunday to Sunday" do
    sunday_after = utc(2026, 11, 8, 23, 31) # Sunday 18:31 EST, just after the Sunday reminder
    assert_equal utc(2026, 11, 9, 23, 30), due(MON | SUN, "18:30", NEW_YORK, sunday_after)
    assert_equal utc(2026, 11, 15, 23, 30), due(SUN, "18:30", NEW_YORK, sunday_after)
  end

  test "end of month and end of year" do
    assert_equal utc(2026, 12, 1, 9), due(ALL, "09:00", "UTC", utc(2026, 11, 30, 9))
    assert_equal utc(2027, 1, 1, 9), due(ALL, "09:00", "UTC", utc(2026, 12, 31, 22))
    assert_equal utc(2028, 2, 29, 9), due(ALL, "09:00", "UTC", utc(2028, 2, 28, 9)) # leap day
  end

  test "the local weekday decides, not the UTC weekday" do
    # Monday 23:30 in Los Angeles (PST, UTC-8) is already Tuesday 07:30 UTC.
    assert_equal utc(2026, 11, 10, 7, 30), due(MON, "23:30", "Pacific Time (US & Canada)", utc(2026, 11, 9))
  end

  test "spring-forward gap: fires once at the first valid instant after the gap" do
    # 02:30 does not exist on 2027-03-14 in New York; clocks jump from 02:00 EST to 03:00 EDT (07:00 UTC).
    friday = due(ALL, "02:30", NEW_YORK, utc(2027, 3, 12, 12))
    assert_equal utc(2027, 3, 13, 7, 30), friday # Saturday 02:30 EST
    gap_day = due(ALL, "02:30", NEW_YORK, friday)
    assert_equal utc(2027, 3, 14, 7, 0), gap_day # 03:00 EDT
    assert_equal utc(2027, 3, 15, 6, 30), due(ALL, "02:30", NEW_YORK, gap_day) # Monday 02:30 EDT, not twice
    assert_equal utc(2027, 3, 14, 7, 0), due(ALL, "02:30", NEW_YORK, utc(2027, 3, 13, 7, 30) + 1)
  end

  test "spring-forward gap with only that Sunday selected still fires once" do
    assert_equal utc(2027, 3, 14, 7, 0), due(SUN, "02:15", NEW_YORK, utc(2027, 3, 8))
    assert_equal utc(2027, 3, 21, 6, 15), due(SUN, "02:15", NEW_YORK, utc(2027, 3, 14, 7, 0))
  end

  test "fall-back overlap: fires once, at the first occurrence" do
    # 01:30 happens twice on 2026-11-01 in New York: 05:30 UTC (EDT) and 06:30 UTC (EST).
    first = due(ALL, "01:30", NEW_YORK, utc(2026, 11, 1, 4))
    assert_equal utc(2026, 11, 1, 5, 30), first
    assert_equal utc(2026, 11, 2, 6, 30), due(ALL, "01:30", NEW_YORK, first) # skips the second 01:30
  end

  test "southern hemisphere DST (Sydney) gap and overlap" do
    # 02:30 does not exist on 2026-10-04 (AEST +10 -> AEDT +11 at 02:00 local, which is 16:00 UTC the day before).
    assert_equal utc(2026, 10, 3, 16, 0), due(ALL, "02:30", "Sydney", utc(2026, 10, 3, 0))
    # 02:30 happens twice on 2027-04-04 (AEDT then AEST): first occurrence is 15:30 UTC on the 3rd.
    assert_equal utc(2027, 4, 3, 15, 30), due(ALL, "02:30", "Sydney", utc(2027, 4, 3, 0))
  end

  test "half-hour and quarter-hour offsets" do
    assert_equal utc(2026, 11, 9, 3, 30), due(MON, "09:00", "Mumbai", utc(2026, 11, 8)) # UTC+5:30
    assert_equal utc(2026, 11, 9, 3, 15), due(MON, "09:00", "Kathmandu", utc(2026, 11, 8)) # UTC+5:45
    assert_equal utc(2026, 11, 9, 23, 30), due(MON, "20:00", "Newfoundland", utc(2026, 11, 8)) # UTC-3:30 (NST)
  end

  test "date line crossing: Auckland, Kiritimati and Samoa" do
    # Auckland is UTC+13 in November: Monday 2026-11-02 08:00 local is Sunday 19:00 UTC.
    assert_equal utc(2026, 11, 1, 19, 0), due(MON, "08:00", "Auckland", utc(2026, 10, 31))
    # Kiritimati is UTC+14: Monday 00:30 local is Sunday 10:30 UTC.
    assert_equal utc(2026, 11, 1, 10, 30), due(MON, "00:30", "Pacific/Kiritimati", utc(2026, 10, 31))
    # Far west of the date line: Honolulu Sunday 23:00 (UTC-10) is Monday 09:00 UTC.
    assert_equal utc(2026, 11, 9, 9, 0), due(SUN, "23:00", "Hawaii", utc(2026, 11, 8, 12))
  end

  test "a skipped calendar day (Samoa, 2011-12-30) still fires once, after the skip" do
    friday_only = 16
    assert_equal utc(2011, 12, 30, 10, 0), due(friday_only, "10:00", "Samoa", utc(2011, 12, 29))
  end

  test "due_between lists every reminder in the half-open range (from, to]" do
    user = Schedule.new(MON | WED, "18:30", NEW_YORK)
    from = utc(2026, 11, 9, 23, 30) # exactly the first reminder: excluded
    assert_equal [ utc(2026, 11, 11, 23, 30), utc(2026, 11, 16, 23, 30) ],
                 Notifications::Reminders.due_between(user, from: from, to: utc(2026, 11, 16, 23, 30))
    assert_empty Notifications::Reminders.due_between(Schedule.new(0, "18:30", NEW_YORK), from: from, to: from + 30.days)
  end

  test "scheduled? recognises exactly the due instants" do
    user = Schedule.new(MON, "18:30", NEW_YORK)
    assert Notifications::Reminders.scheduled?(user, utc(2026, 11, 9, 23, 30))
    assert_not Notifications::Reminders.scheduled?(user, utc(2026, 11, 9, 23, 31))
    assert_not Notifications::Reminders.scheduled?(user, utc(2026, 11, 10, 23, 30))
  end

  test "property: strictly increasing, within 8 days, on a selected local weekday at the exact time" do
    random = Random.new(20_261_112)
    zones = ActiveSupport::TimeZone.all
    start = utc(2025, 1, 1).to_i
    span = utc(2031, 1, 1).to_i - start

    300.times do
      zone = zones.sample(random: random)
      days = random.rand(1..127)
      hour = random.rand(24)
      minute = random.rand(60)
      time = format("%02d:%02d", hour, minute)
      user = Schedule.new(days, time, zone.name)
      cursor = Time.at(start + random.rand(span)).utc
      label = "#{zone.name} days=#{days} time=#{time} after=#{cursor.iso8601}"

      10.times do
        due = Notifications::Reminders.due_at(user, after: cursor)
        assert due, "expected a due time for #{label}"
        assert_operator due, :>, cursor, "not strictly after: #{label}"
        assert_operator due - cursor, :<=, 8 * 86_400, "more than 8 days away: #{label}"

        local = zone.at(due)
        on_time = local.hour == hour && local.min == minute
        in_gap_end = zone.at(due - 1).utc_offset != local.utc_offset && local.sec.zero?
        assert on_time || in_gap_end, "neither exact HH:MM nor the end of a DST gap: #{label} -> #{local}"
        assert days.anybits?(1 << (local.to_date.cwday - 1)), "not a selected weekday: #{label} -> #{local}" if on_time
        cursor = due
      end
    end
  end
end
