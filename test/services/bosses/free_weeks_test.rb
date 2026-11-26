require "test_helper"
require_relative "../../support/bosses_helper"

class Bosses::FreeWeeksTest < ActiveSupport::TestCase
  include BossesHelper

  TUESDAY = Date.new(2026, 11, 24)

  def weeks(bosses, today: TUESDAY) = Bosses::FreeWeeks.new(bosses, today: today)

  def boss(starts_on) = Boss.new(starts_on: starts_on, ends_on: starts_on + 6)

  test "with no bosses the options start at the next Friday and the default is that Friday" do
    free = weeks([])
    assert_equal Date.new(2026, 11, 27), free.default
    assert_equal 10, free.options.size
    assert_equal (0...10).map { |week| Date.new(2026, 11, 27) + (week * 7) }, free.options
    assert free.options.all?(&:friday?)
  end

  test "today counts when it is a Friday" do
    assert_equal Date.new(2026, 11, 27), weeks([], today: Date.new(2026, 11, 27)).options.first
  end

  test "weeks that already have a boss are left out and the default follows the latest boss" do
    free = weeks([ boss(Date.new(2026, 11, 27)), boss(Date.new(2026, 12, 4)), boss(Date.new(2026, 12, 18)) ])
    assert_equal Date.new(2026, 12, 25), free.default, "after the latest boss, not the gap on 11 Dec"
    assert_not_includes free.options, Date.new(2026, 12, 4)
    assert_includes free.options, Date.new(2026, 12, 11), "a gap week can still be filled"
    assert_equal 10, free.options.size
  end

  test "a boss on an odd, non-Friday week blocks every Friday it overlaps" do
    free = weeks([ boss(Date.new(2026, 11, 25)) ]) # Wednesday to Tuesday
    assert_not_includes free.options, Date.new(2026, 11, 27)
    assert_not_includes free.options, Date.new(2026, 12, 1)
  end

  test "the default is the next Friday when every boss is already over" do
    assert_equal Date.new(2026, 11, 27), weeks([ boss(Date.new(2026, 10, 2)) ]).default
  end

  test "missing_next names the first uncovered Friday while it is at most 8 days away, and never one in the past" do
    latest_ends_26 = [ boss(Date.new(2026, 11, 20)) ]
    assert_equal Date.new(2026, 11, 27), weeks(latest_ends_26).missing_next
    assert_equal Date.new(2026, 11, 27), weeks(latest_ends_26, today: Date.new(2026, 11, 19)).missing_next, "exactly 8 days ahead"
    assert_nil weeks(latest_ends_26, today: Date.new(2026, 11, 18)).missing_next, "9 days ahead is too early to nag"
    assert_nil weeks(latest_ends_26 + [ boss(Date.new(2026, 11, 27)) ]).missing_next
    assert_equal Date.new(2026, 11, 27), weeks([ boss(Date.new(2026, 10, 2)) ]).missing_next, "a long-finished boss list: the coming Friday"
    assert_equal Date.new(2026, 11, 27), weeks([]).missing_next
  end

  test "missing_next finds a gap before a later boss" do
    bosses = [ boss(Date.new(2026, 11, 20)), boss(Date.new(2026, 12, 4)) ]
    assert_equal Date.new(2026, 11, 27), weeks(bosses).missing_next
    assert_nil weeks(bosses + [ boss(Date.new(2026, 11, 27)) ]).missing_next, "once the gap is filled the next free Friday is too far away"
  end

  test "missing_current names a running week with no boss, never a Friday or a covered week" do
    assert_equal Date.new(2026, 11, 20), weeks([ boss(Date.new(2026, 11, 13)) ]).missing_current, "Tuesday 24 Nov, the week from 20 Nov has no boss"
    assert_equal Date.new(2026, 11, 27), weeks([ boss(Date.new(2026, 11, 20)) ], today: Date.new(2026, 11, 28)).missing_current
    assert_nil weeks([ boss(Date.new(2026, 11, 20)) ]).missing_current, "the running week has a boss"
    assert_nil weeks([], today: Date.new(2026, 11, 27)).missing_current, "on a Friday the week can still be added"
    assert_nil weeks([ boss(Date.new(2026, 11, 23)) ]).missing_current, "a boss on an odd week covers part of it"
  end
end
