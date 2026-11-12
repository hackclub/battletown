require "test_helper"
require_relative "../../support/plinko_helper"

class PlinkoStandingsTest < ActiveSupport::TestCase
  include PlinkoHelper

  TODAY = Date.new(2026, 11, 12) # a Thursday; the week runs Fri 6 Nov to Thu 12 Nov
  NOW = Time.utc(2026, 11, 12, 15)

  setup do
    @alice = users(:onboarded)
    @bob = users(:new_user)
    [ @alice, @bob ].each { |user| user.update_columns(time_zone: "UTC") }
  end

  def standings(user) = Plinko::Standings.new(user, player: PlinkoPlayer.find_by(user_id: user.id), now: NOW)

  test "weeks run Friday to Thursday" do
    assert_equal Date.new(2026, 11, 6)..Date.new(2026, 11, 12), Plinko::Week.range(Date.new(2026, 11, 12))
    assert_equal Date.new(2026, 11, 6)..Date.new(2026, 11, 12), Plinko::Week.range(Date.new(2026, 11, 6))
    assert_equal Date.new(2026, 11, 13)..Date.new(2026, 11, 19), Plinko::Week.range(Date.new(2026, 11, 13))
  end

  test "own points per day, this week and all time" do
    dropped_on(@alice, TODAY, slot: 0)        # 560
    dropped_on(@alice, TODAY, slot: 4)        # 50
    dropped_on(@alice, Date.new(2026, 11, 7), slot: 1) # 200, this week
    dropped_on(@alice, Date.new(2026, 11, 5), slot: 2) # 100, last week
    dropped_on(@bob, TODAY, slot: 0)

    own = standings(@alice)
    assert_equal 610, own.today_points
    assert_equal 810, own.week_points
    assert_equal 910, own.total_points
    assert_equal 4, own.total_drops
    assert_equal 7, own.days.size
    assert_equal TODAY, own.days.first.date
    assert_equal 2, own.days.first.drops
  end

  test "the leaderboard lists only opted-in players, by nickname and points, and never anyone else" do
    alice = Plinko::Players.for(@alice)
    bob = Plinko::Players.for(@bob)
    dropped_on(@alice, TODAY, slot: 0)
    dropped_on(@bob, TODAY, slot: 1)

    assert_empty standings(@alice).leaderboard, "nobody opted in yet"

    Plinko::Players.opt_in!(@bob, true)
    rows = standings(@alice).leaderboard
    assert_equal [ bob.nickname ], rows.map(&:nickname)
    assert_equal [ 200 ], rows.map(&:points)
    assert_equal [ false ], rows.map(&:you)
    assert_not_includes rows.map(&:nickname), alice.nickname

    Plinko::Players.opt_in!(@alice, true)
    rows = standings(@alice).leaderboard
    assert_equal [ alice.nickname, bob.nickname ], rows.map(&:nickname)
    assert_equal [ true, false ], rows.map(&:you)

    Plinko::Players.opt_in!(@bob, false)
    assert_equal [ alice.nickname ], standings(@bob).leaderboard.map(&:nickname)
  end

  test "players who dropped nothing this week are not listed" do
    Plinko::Players.opt_in!(@alice, true)
    dropped_on(@alice, Date.new(2026, 11, 5), slot: 0) # last week
    assert_empty standings(@alice).leaderboard
  end

  test "the leaderboard is capped at the configured size" do
    config = Plinko::Config.current
    (config.leaderboard_size + 3).times do |n|
      user = User.create!(hca_uid: "plinko-lb-#{n}-#{SecureRandom.hex(3)}", time_zone: "UTC")
      Plinko::Players.opt_in!(user, true)
      dropped_on(user, TODAY, slot: 4)
    end
    assert_equal config.leaderboard_size, standings(@alice).leaderboard.size
  end

  test "rank is private: shown to a player who is not on the leaderboard, and it counts every player who scored" do
    dropped_on(@alice, TODAY, slot: 4) # 50
    dropped_on(@bob, TODAY, slot: 0)   # 560
    Plinko::Players.for(@alice)
    Plinko::Players.for(@bob) # neither opted in

    rank = standings(@alice).rank
    assert_equal 2, rank.position
    assert_equal 2, rank.players
    assert_equal 1, standings(@bob).rank.position
    assert_empty standings(@alice).leaderboard
  end

  test "no rank before the first point of the week" do
    assert_nil standings(@alice).rank
  end
end
