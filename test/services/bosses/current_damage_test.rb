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

  test "at uses the UTC date of the instant, the date Bosses::Damage cuts the week by" do
    # 2026-11-19 23:30 UTC is already Friday 20 Nov in Auckland but still Thursday 19 Nov in UTC: one boss for everybody.
    later = make_boss(starts_on: FRIDAY + 7)

    assert_equal @boss, Bosses::Current.at(Time.utc(2026, 11, 19, 23, 30))
    assert_equal later, Bosses::Current.at(Time.utc(2026, 11, 20, 0, 0))
    assert_equal :none, Bosses::Current.at(Time.utc(2026, 11, 12, 12))
  end

  test "coding alone never damages the boss" do
    add_hours(@user, FRIDAY, 12 * HOUR)
    add_hours(@other, FRIDAY + 2, 12 * HOUR)
    assert_equal 0, Bosses::Damage.for(@boss)
  end

  test "damage sums the seconds of every user's submitted ships in the week" do
    ship_damage(@user, 3_600, on: FRIDAY)
    ship_damage(@user, 1_800, on: THURSDAY)
    ship_damage(@other, 7_200, on: FRIDAY + 2)
    ship_damage(@user, 9_999, on: FRIDAY - 1)
    ship_damage(@other, 9_999, on: THURSDAY + 1)

    assert_equal 12_600, Bosses::Damage.for(@boss)
  end

  test "an approved ship counts at its approved seconds, a submitted one at its coded seconds" do
    ship_damage(@user, 3_600, status: "approved", approved_seconds: 2_700)
    ship_damage(@other, 1_000, status: "submitted")
    assert_equal 3_700, Bosses::Damage.for(@boss)
  end

  test "drafts, withdrawn and rejected ships do not damage the boss" do
    ship_damage(@user, 3_600, status: "draft")
    ship_damage(@user, 3_600, status: "withdrawn")
    ship_damage(@user, 3_600, status: "rejected")
    assert_equal 0, Bosses::Damage.for(@boss)

    ship_damage(@user, 600)
    assert_equal 600, Bosses::Damage.for(@boss)
  end

  test "a rejected ship that is fixed and shipped again is counted once" do
    rejected = ship_damage(@user, 3_600, status: "rejected")
    ship_damage(@user, rejected.coded_seconds)
    assert_equal 3_600, Bosses::Damage.for(@boss)
  end

  test "the week is picked by the UTC date of submitted_at: Friday 00:00 is in, Thursday 23:59:59 is in, the next Friday 00:00 is the next boss" do
    ship_damage(@user, 1, on: Time.utc(2026, 11, 12, 23, 59, 59))
    assert_equal 0, Bosses::Damage.for(@boss), "Thursday 23:59:59 UTC is the week before"
    ship_damage(@user, 10, on: Time.utc(2026, 11, 13, 0, 0, 0))
    ship_damage(@user, 100, on: Time.utc(2026, 11, 19, 23, 59, 59))
    ship_damage(@user, 1_000, on: Time.utc(2026, 11, 20, 0, 0, 0))
    assert_equal 110, Bosses::Damage.for(@boss)
    assert_equal 1_000, Bosses::Damage.for(make_boss(starts_on: FRIDAY + 7))
  end

  test "a ship's own window dates do not decide the week, its submission does" do
    ship = ship_damage(@user, 600, on: FRIDAY + 1)
    ship.update_columns(window_start_date: FRIDAY - 20, window_end_date: FRIDAY - 20, daily_seconds: { (FRIDAY - 20).iso8601 => 600 })
    assert_equal 600, Bosses::Damage.for(@boss)
  end

  test "for_user counts only that user's ships" do
    ship_damage(@user, 3_600)
    ship_damage(@user, 600, status: "withdrawn")
    ship_damage(@other, 7_200)
    assert_equal 3_600, Bosses::Damage.for_user(@boss, @user)
    assert_equal 7_200, Bosses::Damage.for_user(@boss, @other)
    assert_equal 0, Bosses::Damage.for_user(@boss, User.create!(hca_uid: "ident!third", time_zone: "UTC"))
  end

  test "an empty week is zero" do
    assert_equal 0, Bosses::Damage.for(@boss)
  end
end
