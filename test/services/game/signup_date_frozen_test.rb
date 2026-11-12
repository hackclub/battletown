require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/ships_test_support"

# The sign-up cutoff (Hours::Days.first_counted_date) is the local date the account was created on. It is worked out
# once, when the account is created, and again only while onboarding (where the zone is chosen) is unfinished; after
# that a time zone change never moves it, so re-saving the schedule can neither count back-filled hours nor drop
# counted ones.
class Game::SignupDateFrozenTest < ActiveSupport::TestCase
  include BossesHelper
  include ShipsTestSupport

  BEFORE = Date.new(2026, 11, 13)
  SIGNUP = Date.new(2026, 11, 14)
  AFTER = Date.new(2026, 11, 15)

  setup { @boss = make_boss }

  def onboarded_user(created_at, time_zone: "UTC")
    User.create!(hca_uid: "ident!frozen-#{SecureRandom.hex(6)}", time_zone: time_zone, created_at: created_at,
                 onboarded_at: created_at + 600, onboarding_step: User::ONBOARDING_STEPS)
  end

  def counted_now(user, project)
    { first: Hours::Days.first_counted_date(user.reload), damage: Bosses::Damage.for(@boss), window: Ships::Window.call(project).seconds }
  end

  test "moving west after sign-up never counts the back-filled day before it" do
    # 06:00 UTC on the 14th: the 14th in UTC, still the 13th in International Date Line West (UTC-12).
    user = onboarded_user(Time.utc(2026, 11, 14, 6))
    project = make_project(user)
    code(user, BEFORE, 3 * HOUR)
    code(user, SIGNUP, HOUR)

    before = counted_now(user, project)
    assert_equal({ first: SIGNUP, damage: HOUR, window: HOUR }, before)

    user.update!(time_zone: "International Date Line West")
    assert_equal before, counted_now(user, project)
  end

  test "moving east after sign-up never drops the sign-up day" do
    # 18:00 UTC on the 14th: the 14th in UTC, already the 15th in Nuku'alofa (UTC+13).
    user = onboarded_user(Time.utc(2026, 11, 14, 18))
    project = make_project(user)
    code(user, SIGNUP, 2 * HOUR)
    code(user, AFTER, HOUR)

    before = counted_now(user, project)
    assert_equal({ first: SIGNUP, damage: 3 * HOUR, window: 3 * HOUR }, before)

    user.update!(time_zone: "Nuku'alofa")
    assert_equal before, counted_now(user, project)
  end

  test "a new account takes the sign-up date in the zone it was created with" do
    west = User.create!(hca_uid: "ident!frozen-west", time_zone: "Pacific Time (US & Canada)", created_at: Time.utc(2026, 11, 14, 3))
    east = User.create!(hca_uid: "ident!frozen-east", time_zone: "Auckland", created_at: Time.utc(2026, 11, 13, 12))
    plain = User.create!(hca_uid: "ident!frozen-utc", created_at: Time.utc(2026, 11, 14, 23, 59))
    assert_equal [ BEFORE, SIGNUP, SIGNUP ], [ west, east, plain ].map { |user| Hours::Days.first_counted_date(user.reload) }
  end

  test "choosing a zone while onboarding is unfinished still sets the sign-up date, finishing freezes it" do
    user = User.create!(hca_uid: "ident!frozen-onboarding", created_at: Time.utc(2026, 11, 14, 6))
    assert_equal SIGNUP, Hours::Days.first_counted_date(user.reload)

    user.update!(time_zone: "International Date Line West")
    assert_equal BEFORE, Hours::Days.first_counted_date(user.reload), "the zone picked during onboarding is the one the account started in"

    user.update!(onboarded_at: Time.utc(2026, 11, 14, 7))
    user.update!(time_zone: "UTC")
    assert_equal BEFORE, Hours::Days.first_counted_date(user.reload)
  end

  test "the all-users SQL reads the same frozen date" do
    user = onboarded_user(Time.utc(2026, 11, 14, 6))
    add_hours(user, BEFORE, 3 * HOUR)
    add_hours(user, SIGNUP, HOUR)
    user.update!(time_zone: "International Date Line West")

    assert_equal HOUR, Hours::Totals.seconds_in_range(BEFORE..SIGNUP)
    assert_equal 0, Hours::Totals.active_user_count(BEFORE)
    assert_equal 1, Hours::Totals.active_user_count(SIGNUP)
  end

  test "days_before_signup_counted still counts back from the frozen date, in Ruby and in SQL" do
    user = onboarded_user(Time.utc(2026, 11, 14, 6))
    add_hours(user, BEFORE - 1, 2 * HOUR)
    add_hours(user, BEFORE, 3 * HOUR)
    add_hours(user, SIGNUP, HOUR)
    user.update!(time_zone: "International Date Line West")

    with_hours_config(days_before_signup_counted: 1) do
      assert_equal BEFORE, Hours::Days.first_counted_date(user.reload)
      assert_equal 4 * HOUR, Hours::Totals.seconds_by_date(user, (BEFORE - 1)..SIGNUP).values.sum
      assert_equal 4 * HOUR, Hours::Totals.seconds_in_range((BEFORE - 1)..SIGNUP)
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
