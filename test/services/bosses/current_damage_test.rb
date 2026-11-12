require "test_helper"
require_relative "../../support/bosses_helper"

class Bosses::CurrentDamageTest < ActiveSupport::TestCase
  include BossesHelper

  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
    @boss = make_boss
  end

  test "for(date) covers both ends and is :none outside" do
    assert_equal @boss, Bosses::Current.for(FRIDAY)
    assert_equal @boss, Bosses::Current.for(THURSDAY)
    assert_equal :none, Bosses::Current.for(FRIDAY - 1)
    assert_equal :none, Bosses::Current.for(THURSDAY + 1)
  end

  test "for(date) is :none in a gap between two bosses" do
    later = make_boss(starts_on: FRIDAY + 14)
    assert_equal :none, Bosses::Current.for(THURSDAY + 3)
    assert_equal later, Bosses::Current.for(FRIDAY + 14)
  end

  test "for_user uses the user's local today" do
    # 2026-11-19 23:30 UTC is already Friday 20 Nov in Auckland and still Thursday 19 Nov in UTC.
    nz = make_boss(starts_on: FRIDAY + 7)
    @user.update!(time_zone: "Auckland")
    utc = users(:new_user).tap { |user| user.update!(time_zone: "UTC") }
    now = Time.utc(2026, 11, 19, 23, 30)

    assert_equal nz, Bosses::Current.for_user(@user, now: now)
    assert_equal @boss, Bosses::Current.for_user(utc, now: now)
    assert_equal :none, Bosses::Current.for_user(utc, now: Time.utc(2026, 11, 12, 12))
  end

  test "damage sums every user's raw seconds on the boss dates only" do
    add_hours(@user, FRIDAY, 3_600)
    add_hours(@user, THURSDAY, 1_800)
    add_hours(@other, FRIDAY + 2, 7_200)
    add_hours(@user, FRIDAY - 1, 9_999)
    add_hours(@other, THURSDAY + 1, 9_999)

    assert_equal 12_600, Bosses::Damage.for(@boss)
  end

  test "damage has no bonus or scaling and is clamped at zero by adjustments" do
    add_hours(@user, FRIDAY, 600)
    assert_equal 600, Bosses::Damage.for(@boss)
    add_hours(@user, FRIDAY, -5_000, source: "adjustment")
    assert_equal 0, Bosses::Damage.for(@boss)
  end

  test "an empty week is zero" do
    assert_equal 0, Bosses::Damage.for(@boss)
  end
end
