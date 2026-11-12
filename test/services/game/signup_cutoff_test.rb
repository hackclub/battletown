require "test_helper"
require_relative "../../support/coins_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/ships_test_support"

# Hours dated before the local date a person signed up on stay in the ledger but count for nothing in the game; the
# sign-up date itself counts fully. One rule (Hours::Days.first_counted_date) for boss damage, streaks, coins and the
# dashboard, so a newcomer's backfilled hours never land on the community boss.
class Game::SignupCutoffTest < ActiveSupport::TestCase
  include CoinsHelper
  include BossesHelper
  include ShipsTestSupport

  # The boss week is Friday 13 to Thursday 19 November. The newcomer signs up on Saturday the 14th (UTC).
  BEFORE = Date.new(2026, 11, 13)
  SIGNUP = Date.new(2026, 11, 14)
  AFTER = Date.new(2026, 11, 15)

  setup do
    @user = build_user(created_on: SIGNUP)
    @veteran = users(:onboarded)
    @boss = make_boss
    @project = make_project(@user)
    code(@user, BEFORE, 2 * HOUR)
    code(@user, SIGNUP, HOUR)
    code(@user, AFTER, 30 * 60)
    add_hours(@veteran, BEFORE, 900)
  end

  test "the first counted date is the sign-up date in the user's zone" do
    assert_equal SIGNUP, Hours::Days.first_counted_date(@user)
  end

  test "the ledger keeps the earlier hours" do
    assert_equal (2 * HOUR) + HOUR + (30 * 60), HourEntry.where(user_id: @user.id).sum(:seconds)
    assert_equal 2 * HOUR, Hours::Totals.ledger_seconds_by_date(@user, BEFORE..AFTER)[BEFORE]
  end

  test "boss damage counts the sign-up day and later, never the day before" do
    assert_equal HOUR + (30 * 60) + 900, Bosses::Damage.for(@boss)
    assert_equal({ SIGNUP => HOUR, AFTER => 30 * 60 }, Hours::Totals.seconds_by_date(@user, BEFORE..AFTER))
    assert_equal 0, Hours::Totals.seconds_for_date(@user, BEFORE)
    assert_equal HOUR, Hours::Totals.seconds_for_date(@user, SIGNUP)
    assert_equal 1, Hours::Totals.active_user_count(BEFORE), "only the veteran was active the day before"
    assert_equal 1, Hours::Totals.active_user_count(SIGNUP)
  end

  test "pre-sign-up hours cannot defeat the boss" do
    @boss.update_columns(hp_seconds: HOUR + (30 * 60) + 900 + 1)
    assert_not Bosses::CheckDefeat.call(@boss), "the raw ledger is well past the health, the counted damage is not"

    add_hours(@user, AFTER + 1, 1)
    assert @boss.reload.defeated_at.present?
  end

  test "the boss card counts the user's own damage from the sign-up day" do
    presenter = Bosses::Presenter.new(user: @user, today: AFTER + 1)
    assert_equal HOUR + (30 * 60), presenter.contributed_seconds_this_week
  end

  test "settled streak days start on the sign-up day, which counts fully" do
    Game::Settle.call(@user, through: Time.utc(2026, 11, 17, 6))
    rows = DailyResult.where(user_id: @user.id).chronological.to_a
    assert_equal [ SIGNUP, AFTER, AFTER + 1 ], rows.map(&:local_date)
    assert_equal [ HOUR, 30 * 60, 0 ], rows.map(&:raw_seconds)
    assert_equal [ true, true, false ], rows.map(&:quick_met)
    assert_equal [ true, false, false ], rows.map(&:goal_met)
    assert_equal [ 1, 2 ], rows.first(2).map(&:streak_15)
  end

  test "the dashboard's live streak and today numbers ignore the day before" do
    dashboard = Dashboard::Presenter.new(user: @user, now: Time.utc(2026, 11, 15, 12))
    assert_equal 30 * 60, dashboard.today.seconds
    assert_equal 2, dashboard.quick_streak.days, "the sign-up day and today, not the day before"
    assert_equal 1, dashboard.goal_streak.days, "today has not reached the goal; the sign-up day's goal streak is carried"
    assert_nil dashboard.quick_streak.best_text
    assert_equal HOUR + (30 * 60), dashboard.boss.contributed_seconds_this_week
  end

  test "the ship window and its coins start on the sign-up day" do
    window = Ships::Window.call(@project)
    assert_equal HOUR + (30 * 60), window.seconds
    assert_equal SIGNUP, window.start_date

    ship = submit_ship(@project)
    assert_equal [ SIGNUP, AFTER ], ship.window_dates
    result = Ships::Approve.call(ship: ship, reviewer: @veteran, approved_seconds: ship.coded_seconds, now: Time.utc(2026, 11, 17, 6))
    assert_equal 15, result.credit.base_coins, "1.5 hours at 10 coins, nothing for the two hours before sign-up"
  end

  test "SQL and Ruby agree on the sign-up date across zones" do
    # 03:00 UTC on the 14th is still the 13th in Los Angeles; 12:00 UTC on the 13th is already the 14th in Auckland.
    west = build_user(created_on: SIGNUP).tap { |user| user.update_columns(time_zone: "Pacific Time (US & Canada)", created_at: Time.utc(2026, 11, 14, 3)) }
    east = build_user(created_on: BEFORE).tap { |user| user.update_columns(time_zone: "Auckland", created_at: Time.utc(2026, 11, 13, 12)) }
    assert_equal BEFORE, Hours::Days.first_counted_date(west)
    assert_equal SIGNUP, Hours::Days.first_counted_date(east)

    [ west, east ].each do |user|
      add_hours(user, BEFORE - 1, 600)
      add_hours(user, BEFORE, 60)
      add_hours(user, SIGNUP, 6)
    end
    range = (BEFORE - 1)..SIGNUP
    assert_equal 60 + 6 + 6, [ west, east ].sum { |user| Hours::Totals.seconds_by_date(user, range).values.sum }
    per_user = [ west, east, @user, @veteran ].sum { |user| Hours::Totals.seconds_by_date(user, range).values.sum }
    assert_equal per_user, Hours::Totals.seconds_in_range(range), "the all-users SQL applies the same cutoff as the per-user Ruby"
  end

  test "days_before_signup_counted lets earlier days count, the same way everywhere" do
    with_hours_config(days_before_signup_counted: 1) do
      assert_equal BEFORE, Hours::Days.first_counted_date(@user)
      assert_equal (2 * HOUR) + HOUR + (30 * 60) + 900, Bosses::Damage.for(@boss)
      assert_equal 2 * HOUR, Hours::Totals.seconds_for_date(@user, BEFORE)
      assert_equal BEFORE, Ships::Window.call(@project).start_date
    end
  end

  private

  def with_hours_config(**changes)
    original = Hours::Config.current
    Hours::Config.instance_variable_set(:@current, original.with(**changes))
    yield
  ensure
    Hours::Config.instance_variable_set(:@current, original)
  end
end
