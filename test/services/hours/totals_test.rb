require "test_helper"

class Hours::TotalsTest < ActiveSupport::TestCase
  D = Date.new(2026, 11, 10)

  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
  end

  def add(user, date, seconds, source: "manual", key: SecureRandom.hex(6))
    HourEntry.create!(user: user, local_date: date, seconds: seconds, source: source, note: "t", idempotency_key: key)
  end

  test "seconds_by_date sums per local date for one user, inside the range only" do
    add(@user, D, 600)
    add(@user, D, 300)
    add(@user, D + 1, 900)
    add(@user, D + 5, 1_200)
    add(@other, D, 7_200)

    assert_equal({ D => 900, D + 1 => 900 }, Hours::Totals.seconds_by_date(@user, D..(D + 1)))
    assert_equal({ D => 900, D + 1 => 900 }, Hours::Totals.seconds_by_date(@user, D...(D + 2)))
    assert_equal({ D => 900, D + 1 => 900, D + 5 => 1_200 }, Hours::Totals.seconds_by_date(@user, D..))
    assert_equal({}, Hours::Totals.seconds_by_date(@user, (D - 9)..(D - 1)))
  end

  test "seconds_for_date" do
    add(@user, D, 600)
    add(@user, D, -100, source: "adjustment")
    add(@other, D, 5_000)

    assert_equal 500, Hours::Totals.seconds_for_date(@user, D)
    assert_equal 0, Hours::Totals.seconds_for_date(@user, D + 1)
  end

  test "totals are net of adjustments and never negative" do
    add(@user, D, 600)
    add(@user, D, -900, source: "adjustment")

    assert_equal 0, Hours::Totals.seconds_for_date(@user, D)
    assert_equal({}, Hours::Totals.seconds_by_date(@user, D..D))
    assert_equal 0, Hours::Totals.seconds_in_range(D..D)
  end

  test "seconds_in_range adds up every user" do
    add(@user, D, 600)
    add(@other, D, 1_800)
    add(@other, D + 1, 60)
    add(@other, D + 9, 9_999)

    assert_equal 2_460, Hours::Totals.seconds_in_range(D..(D + 1))
    assert_equal 2_400, Hours::Totals.seconds_in_range(D..D)
    assert_equal 0, Hours::Totals.seconds_in_range((D - 5)..(D - 1))
  end

  test "active_user_count needs 900 seconds in total on that date" do
    add(@user, D, 899)
    add(@other, D, 450)
    add(@other, D, 450) # two rows, 900 in all
    assert_equal 1, Hours::Totals.active_user_count(D)

    add(@user, D, 1)
    assert_equal 2, Hours::Totals.active_user_count(D)
    assert_equal 0, Hours::Totals.active_user_count(D + 1)
  end

  test "active_user_count ignores a day that an adjustment pushed under the minimum" do
    add(@user, D, 1_000)
    add(@user, D, -200, source: "adjustment")
    assert_equal 0, Hours::Totals.active_user_count(D)
    assert_equal 1, Hours::Totals.active_user_count(D, minimum: 800)
  end
end
