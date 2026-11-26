require "test_helper"
require_relative "../../support/profiles_helper"

# The two sums a profile adds to Bosses::Damage: a person's damage over every week, and the bosses they earned the slayer badge on.
class BossesDamageAllTimeTest < ActiveSupport::TestCase
  include ProfilesHelper

  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
    @week1 = make_boss(starts_on: Date.new(2026, 11, 6), defeated_at: Time.utc(2026, 11, 8))
    @week2 = make_boss(starts_on: Date.new(2026, 11, 13), defeated_at: Time.utc(2026, 11, 14))
    @week3 = make_boss(starts_on: Date.new(2026, 11, 20))
  end

  test "all-time is the sum of the person's submitted and approved ships, at approved hours, in any week" do
    ship_damage(@user, 3600, on: Date.new(2026, 11, 6))
    ship_damage(@user, 7200, on: Date.new(2026, 11, 20), status: "approved", approved_seconds: 1800)
    ship_damage(@user, 9999, on: Date.new(2026, 11, 13), status: "draft")
    ship_damage(@user, 9999, on: Date.new(2026, 11, 13), status: "rejected")
    ship_damage(@user, 9999, on: Date.new(2026, 11, 13), status: "withdrawn")
    ship_damage(@other, 5000, on: Date.new(2026, 11, 13))
    assert_equal 3600 + 1800, Bosses::Damage.all_time_for_user(@user)
    assert_equal 5000, Bosses::Damage.all_time_for_user(@other)
    assert_equal 0, Bosses::Damage.all_time_for_user(User.new(id: 0))
  end

  test "bosses slain counts fallen bosses where the person's own shipped seconds reach the slayer mark" do
    mark = Bosses::Config.current.slayer_seconds
    ship_damage(@user, mark, on: Date.new(2026, 11, 6))          # week 1: exactly the mark, boss fell
    ship_damage(@user, mark - 1, on: Date.new(2026, 11, 13))     # week 2: one second short
    ship_damage(@user, mark, on: Date.new(2026, 11, 20))         # week 3: boss still standing
    assert_equal 1, Bosses::Damage.slain_count(@user)
    ship_damage(@user, 1, on: Date.new(2026, 11, 14))            # week 2 now reaches it, from two ships
    assert_equal 2, Bosses::Damage.slain_count(@user)
    assert_equal 0, Bosses::Damage.slain_count(@other)
  end

  test "a ship on the last day of the boss week counts for that boss and one on the next day does not" do
    mark = Bosses::Config.current.slayer_seconds
    ship_damage(@user, mark, on: Time.utc(2026, 11, 12, 23, 59, 59)) # Thursday night: week 1
    ship_damage(@user, mark, on: Time.utc(2026, 11, 20, 0, 0, 0))    # Friday 00:00: week 3 (still standing)
    assert_equal 1, Bosses::Damage.slain_count(@user)
  end

  test "slain count is one query" do
    ship_damage(@user, 1000, on: Date.new(2026, 11, 6))
    queries = count_queries { Bosses::Damage.slain_count(@user) }
    assert_equal 1, queries
  end
end
