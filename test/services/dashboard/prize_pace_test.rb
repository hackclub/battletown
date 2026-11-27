require "test_helper"
require_relative "../../support/shop_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/ships_test_support"

# "Am I on track for my prize?": coins still missing, turned into coding time at today's bonus, judged against the pledged pace.
class Dashboard::PrizePaceTest < ActiveSupport::TestCase
  include ShopTestHelper
  include BossesHelper
  include ShipsTestSupport

  NOW = Time.utc(2026, 11, 20, 12) # a Friday; the user's zone is UTC

  setup do
    @user = users(:onboarded) # T-shirt, 50 coins, signed up 1 Jan
    @user.update_columns(coding_days: 0b0011111, pace_minutes: 60) # monday to friday, an hour a day: 300 minutes a week
    @today = Date.new(2026, 11, 20)
  end

  def pace(bonus_bps: 0, now: NOW)
    presenter = Dashboard::Presenter.new(user: @user.reload, now: now)
    presenter.define_singleton_method(:active_bonus_bps) { bonus_bps }
    presenter.prize_pace
  end

  test "no prize, or a free one, means no check" do
    @user.update_columns(prize_key: nil)
    assert_nil pace
    @user.update_columns(prize_key: "signup_sticker")
    assert_nil pace
  end

  test "the coins missing become coding time at the base rate: 50 coins is 5 hours" do
    assert_equal "About 5 hours of coding to go", pace.to_go
    assert_nil pace.bonus
  end

  test "an active bonus shortens the time left, and says so" do
    result = pace(bonus_bps: 1000) # 10%: 11 coins an hour
    assert_equal "About 4 hours 33 minutes of coding to go", result.to_go
    assert_equal "with your 10% bonus", result.bonus
    assert_equal 1000, result.bonus_percent
  end

  test "coins already in the balance count, and so does time coded on the project since its last ship" do
    give_coins(@user, 20)
    assert_equal "About 3 hours of coding to go", pace.to_go

    project = make_project(@user)
    code(@user, @today - 1, 3600)
    assert_equal "About 2 hours of coding to go", pace.to_go, "an hour coded and not yet shipped is 10 coins on its way"
  end

  test "enough coins, or enough coded time that shipping will do it, is reached" do
    give_coins(@user, 50)
    assert_equal :reached, pace.state
    assert_equal "Enough for it", pace.badge
    assert_match(/Spend them in the shop/, pace.to_go)
    assert_nil pace.plan

    other = users(:new_user)
    other.update_columns(prize_key: "tshirt", signed_up_on: Date.new(2026, 1, 1), created_at: Time.utc(2026, 1, 1))
    @user = other
    make_project(other)
    code(other, @today - 1, 5 * 3600)
    assert_equal :reached, pace.state
    assert_match(/Ship your time/, pace.to_go)
  end

  test "the first counted day has no verdict yet" do
    @user.update_columns(created_at: Time.utc(2026, 11, 20, 8), signed_up_on: @today)
    assert_equal :starting, pace.state
    assert_equal "Just starting", pace.badge
  end

  test "on track when the recent days add up to the pledge for those days, behind when they do not" do
    @user.update_columns(created_at: Time.utc(2026, 11, 1), signed_up_on: Date.new(2026, 11, 1))
    assert_equal :behind, pace.state, "nothing coded this week against 300 pledged minutes"

    (0..6).each { |back| add_hours(@user, @today - back, 2400) } # 7 x 40 = 280 minutes: just under 300
    assert_equal :behind, pace.state

    add_hours(@user, @today, 1200) # 300 minutes in all
    assert_equal :on_track, pace.state
    assert_equal "On track", pace.badge
  end

  test "a person in their second day is judged on the days they have had" do
    @user.update_columns(created_at: Time.utc(2026, 11, 19, 8), signed_up_on: Date.new(2026, 11, 19))
    assert_equal :behind, pace.state, "two days in, no coding: pledge for two of seven days is about 86 minutes"
    add_hours(@user, @today - 1, 5400)
    assert_equal :on_track, pace.state
  end

  test "the plan says where the pledge lands: the coding days and the pace set the weekly time" do
    # 5 hours to go at 300 minutes a week is 1 week: seven days on
    assert_equal "At 60 minutes a day, around 27 Nov", pace.plan

    @user.update_columns(pace_minutes: 15) # 75 minutes a week: 5 hours is four weeks
    assert_equal "At 15 minutes a day, around 18 Dec", pace.plan

    @user.update_columns(coding_days: 0, pace_minutes: nil) # no days picked: every day, at the default hour
    assert_equal "At 60 minutes a day, around 25 Nov", pace.plan
  end

  test "the deflation, crew and quest bonuses are not guessed at: the rate is only the base plus the one active bonus" do
    assert_equal "About 5 hours of coding to go", pace(bonus_bps: 0).to_go
    assert_equal "About 4 hours 10 minutes of coding to go", pace(bonus_bps: 2000).to_go, "20%: 12 coins an hour"
  end
end
