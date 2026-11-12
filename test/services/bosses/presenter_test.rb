require "test_helper"
require_relative "../../support/bosses_helper"

class Bosses::PresenterTest < ActiveSupport::TestCase
  include BossesHelper

  MONDAY = Date.new(2026, 11, 16)

  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
    @boss = make_boss(name: "Boss 1")
  end

  def present(today: MONDAY, user: @user) = Bosses::Presenter.new(user: user, today: today)

  test "no boss before the first one, with the arrival date" do
    presenter = present(today: FRIDAY - 2)
    assert_equal :none, presenter.state
    assert_not presenter.boss?
    assert_nil presenter.boss_name
    assert_nil presenter.art_path
    assert_equal FRIDAY, presenter.upcoming_on
    assert_equal "The next boss arrives Friday 13 November.", presenter.upcoming_text
    assert_equal "No boss right now.", presenter.summary
    assert_equal 0, presenter.remaining_seconds
    assert_nil presenter.contributed_text
  end

  test "no boss after the last one has been gone for more than the afterglow" do
    assert_equal :none, present(today: THURSDAY + 9).state
    assert_nil present(today: THURSDAY + 9).upcoming_text
  end

  test "in progress: bar, hours to go truncated, days left and end day" do
    add_hours(@other, FRIDAY, (310 * HOUR))
    presenter = present

    assert_equal :in_progress, presenter.state
    assert_equal "Boss 1", presenter.boss_name
    assert_equal "bosses/placeholder.webp", presenter.art_path
    assert_predicate presenter.art_alt, :present?
    assert_equal 62, presenter.damage_percent
    assert_equal 38, presenter.health_percent
    assert_in_delta 0.62, presenter.damage_ratio, 0.0001
    assert_in_delta 0.38, presenter.health_ratio, 0.0001
    assert_equal 190 * HOUR, presenter.remaining_seconds
    assert_equal "about 190 hours to go", presenter.hours_to_go_text
    assert_equal 4, presenter.days_left
    assert_equal THURSDAY, presenter.ends_on
    assert_equal "Thursday", presenter.end_day_name
    assert_equal "Boss at 38% health, about 190 hours to go. Ends Thursday.", presenter.summary
    assert_equal "4 days left, ends Thursday", presenter.days_left_text
    assert_equal 0, presenter.overkill_seconds
    assert_not presenter.user_slayer?
  end

  test "hours to go are truncated, never rounded up" do
    add_hours(@other, FRIDAY, (310 * HOUR) - 3_599)
    assert_equal "about 190 hours to go", present.hours_to_go_text, "190 h 59 m 59 s is still 190 hours"

    add_hours(@other, FRIDAY, 3_599 + 1)
    assert_equal "about 189 hours to go", present.hours_to_go_text
  end

  test "an hour or less to go" do
    add_hours(@other, FRIDAY, (500 * HOUR) - 3_600)
    assert_equal "about 1 hour to go", present.hours_to_go_text
    add_hours(@other, FRIDAY, 1)
    assert_equal "less than an hour to go", present.hours_to_go_text
  end

  test "a bar that has barely moved still reads 100% health" do
    add_hours(@other, FRIDAY, 36)
    assert_equal 100, present.health_percent
    assert_equal 0, present.damage_percent
    add_hours(@other, FRIDAY, HOUR)
    assert_equal 100, present.health_percent, "1 hour of 500 is still 0%"
  end

  test "the last day says it ends today" do
    presenter = present(today: THURSDAY)
    assert_equal 1, presenter.days_left
    assert_equal "Last day, make it count", presenter.days_left_text
    assert_match(/Ends today\.\z/, presenter.summary)
  end

  test "defeated: celebration state, overkill shown, bar empty, kept for the rest of the week" do
    add_hours(@other, FRIDAY, (500 * HOUR) + (2 * HOUR) + (13 * 60))
    presenter = present

    assert_equal :defeated, presenter.state
    assert_equal 100, presenter.damage_percent
    assert_equal 0, presenter.health_percent
    assert_equal 1.0, presenter.damage_ratio
    assert_equal 0, presenter.remaining_seconds
    assert_nil presenter.hours_to_go_text
    assert_equal 2 * HOUR + 13 * 60, presenter.overkill_seconds
    assert_equal "2 hours 13 minutes", presenter.overkill_text
    assert_equal "Boss defeated. Overkill: 2 hours 13 minutes.", presenter.summary
    assert_equal :defeated, present(today: THURSDAY).state
    assert_equal :defeated, present(today: THURSDAY + 3).state, "and for a few days after the week"
  end

  test "exact health: defeated, no overkill" do
    add_hours(@other, FRIDAY, 500 * HOUR)
    presenter = present
    assert_equal :defeated, presenter.state
    assert_nil presenter.overkill_text
    assert_equal "Boss defeated.", presenter.summary
  end

  test "a recorded defeat stays defeated when a correction later lowers the damage" do
    add_hours(@other, FRIDAY, 600 * HOUR)
    assert @boss.reload.defeated?
    add_hours(@other, FRIDAY, -400 * HOUR, source: "adjustment")

    presenter = present
    assert_equal :defeated, presenter.state
    assert_equal 0, presenter.health_percent
    assert_equal 0, presenter.overkill_seconds
  end

  test "escaped: the week is over and the boss still stands, with no penalty" do
    add_hours(@other, FRIDAY, 100 * HOUR)
    presenter = present(today: THURSDAY + 1)

    assert_equal :escaped, presenter.state
    assert_equal 0, presenter.days_left
    assert_nil presenter.days_left_text
    assert_equal "Boss escaped with 80% health left, about 400 hours to go.", presenter.summary
    assert_equal :escaped, present(today: THURSDAY + 7).state
    assert_equal :none, present(today: THURSDAY + 8).state
  end

  test "after an escape the next boss shows a gentle note for the first days only" do
    make_boss(starts_on: FRIDAY + 7, name: "Boss 2")
    assert_equal "Boss 1", present(today: FRIDAY + 7).previous_escaped_name
    assert_equal :in_progress, present(today: FRIDAY + 7).state
    assert_equal "Boss 2", present(today: FRIDAY + 7).boss_name
    assert_nil present(today: FRIDAY + 10).previous_escaped_name

    add_hours(@other, FRIDAY, 500 * HOUR)
    assert_nil present(today: FRIDAY + 7).previous_escaped_name, "a boss that fell did not escape"
  end

  test "slayer needs at least 900 coded seconds in the boss week, while it is defeated" do
    add_hours(@other, FRIDAY, 500 * HOUR)

    add_hours(@user, FRIDAY, 899)
    assert_not present.user_slayer?
    assert present.slayer_still_possible?
    assert_not present(today: THURSDAY + 1).slayer_still_possible?, "the week is over"

    add_hours(@user, FRIDAY + 3, 1)
    assert present.user_slayer?
    assert_not present.slayer_still_possible?
    assert present(today: THURSDAY + 2).user_slayer?, "the badge stays after the week"
  end

  test "slayer counts only the boss week, and only when the boss fell" do
    add_hours(@user, FRIDAY - 1, 5_000)
    add_hours(@user, THURSDAY + 1, 5_000)
    add_hours(@other, FRIDAY, 500 * HOUR)
    assert_not present.user_slayer?

    add_hours(@user, FRIDAY, 5_000)
    assert present.user_slayer?

    other_boss = make_boss(starts_on: FRIDAY + 7)
    add_hours(@user, FRIDAY + 7, 5_000)
    assert_equal :in_progress, present(today: FRIDAY + 7).state
    assert_not present(today: FRIDAY + 7).user_slayer?, "a standing boss gives no badge (#{other_boss.name})"
  end

  test "own contribution is the current user's alone" do
    add_hours(@user, FRIDAY, 90 * 60)
    add_hours(@user, FRIDAY + 2, 5 * 60)
    add_hours(@other, FRIDAY, 40 * HOUR)

    assert_equal 95 * 60, present.contributed_seconds_this_week
    assert_equal "You've dealt 1 hour 35 minutes of damage this week.", present.contributed_text
    assert_equal 40 * HOUR, present(user: @other).contributed_seconds_this_week
  end

  test "nothing contributed yet invites the first hit" do
    assert_equal 0, present.contributed_seconds_this_week
    assert_equal "Code for 15 minutes to land your first hit.", present.contributed_text
  end

  test "an ended week talks in the past tense" do
    add_hours(@user, FRIDAY, 45 * 60)
    assert_equal "You dealt 45 minutes of damage.", present(today: THURSDAY + 1).contributed_text
  end

  test "community_active_today counts people at 15 minutes on the user's local today, and only counts" do
    add_hours(@user, MONDAY, 900)
    add_hours(@other, MONDAY, 899)
    add_hours(@other, MONDAY - 1, 9_000)
    third = User.create!(hca_uid: "ident!third", time_zone: "UTC")
    add_hours(third, MONDAY, 3_600)

    presenter = present
    assert_equal 2, presenter.community_active_today
    assert_equal "2 people coded today.", presenter.community_text
    assert_equal "Be the first to code today.", present(today: MONDAY + 1).community_text
  end

  test "community text for exactly one person" do
    add_hours(@user, MONDAY, 900)
    assert_equal "1 person coded today.", present.community_text
  end

  test "the default today is the user's local date" do
    travel_to Time.utc(2026, 11, 16, 12) do
      assert_equal :in_progress, Bosses::Presenter.new(user: @user).state
    end
    travel_to Time.utc(2026, 11, 12, 12) do
      assert_equal :none, Bosses::Presenter.new(user: @user).state
    end
  end

  test "human_duration" do
    assert_equal "less than a minute", Bosses::Presenter.human_duration(59)
    assert_equal "1 minute", Bosses::Presenter.human_duration(60)
    assert_equal "1 hour", Bosses::Presenter.human_duration(3_600)
    assert_equal "3 hours 1 minute", Bosses::Presenter.human_duration(3 * 3_600 + 61)
  end

  test "preview builds every state without touching the database" do
    %i[in_progress defeated escaped none].each do |state|
      presenter = Bosses::Presenter.preview(state: state, health_percent: 62, today: MONDAY)
      assert_equal state, presenter.state, state.to_s
    end
    assert_equal 62, Bosses::Presenter.preview(state: :in_progress, health_percent: 62, today: MONDAY).health_percent
    assert_equal 100, Bosses::Presenter.preview(state: :in_progress, health_percent: 100, today: MONDAY).health_percent
    assert_equal :defeated, Bosses::Presenter.preview(state: :in_progress, health_percent: 0, today: MONDAY).state
    assert_equal 1, Boss.count, "preview wrote nothing"
  end
end
