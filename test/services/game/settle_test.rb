require "test_helper"
require_relative "../../support/coins_helper"

class Game::SettleTest < ActiveSupport::TestCase
  include CoinsHelper

  D = ->(day) { Date.new(2026, 11, day) }

  setup do
    @user = build_user(created_on: Date.new(2026, 11, 1))
    @source = StubHoursSource.new
  end

  def settle(now, source: @source, user: @user) = Game::Settle.call(user, through: now, source: source)

  def rows(user = @user) = DailyResult.where(user_id: user.id).chronological

  test "nothing is settled before midnight plus grace" do
    assert_empty settle(Time.utc(2026, 11, 2, 5, 59, 59))
    assert_equal 0, rows.count
  end

  test "the first date is the creation date and it settles at the next midnight plus 6 hours" do
    written = settle(Time.utc(2026, 11, 2, 6, 0, 0))
    assert_equal [ D[1] ], written.map(&:local_date)
  end

  test "each settled day gets a row built from the stored previous state" do
    @source.seconds = { D[1] => 900, D[2] => 4000, D[3] => 0, D[4] => 900 }
    settle(Time.utc(2026, 11, 5, 6, 0, 0))
    list = rows.to_a
    assert_equal (D[1]..D[4]).to_a, list.map(&:local_date)
    assert_equal [ 1, 2, 2, 3 ], list.map(&:streak_15)
    assert_equal [ 500, 700, 0, 810 ], list.map(&:bonus_bps)
    assert_equal [ false, true, false, false ], list.map(&:goal_met)
    assert_equal [ false, false, true, false ], list.map(&:freeze_used)
    assert_equal [ 0, 1, 0, 0 ], list.map(&:goal_streak)
    assert_equal [ 900, 4000, 0, 900 ], list.map(&:raw_seconds)
  end

  test "settling is idempotent" do
    @source.seconds = quick_days(D[1]..D[3])
    first = settle(Time.utc(2026, 11, 10, 12))
    second = settle(Time.utc(2026, 11, 10, 12))
    assert_equal 9, first.size
    assert_empty second
    assert_equal 9, rows.count
  end

  test "settling later continues from the last row rather than starting over" do
    @source.seconds = quick_days(D[1]..D[10])
    settle(Time.utc(2026, 11, 4, 12))
    assert_equal 3, rows.count
    settle(Time.utc(2026, 11, 8, 12))
    assert_equal [ 1, 2, 3, 4, 5, 6, 7 ], rows.map(&:streak_15)
  end

  test "the whole history in one go equals settling day by day" do
    seconds = { D[1] => 900, D[2] => 900, D[3] => 0, D[4] => 0, D[5] => 900, D[6] => 3600 }
    one_go = build_user
    stepwise = build_user
    source = StubHoursSource.new(seconds)
    settle(Time.utc(2026, 11, 8, 12), source: source, user: one_go)
    (2..8).each { |day| settle(Time.utc(2026, 11, day, 12), source: source, user: stepwise) }
    columns = %w[local_date raw_seconds quick_met goal_met freeze_used streak_15 goal_streak freeze_available days_since_freeze bonus_bps]
    assert_equal rows(one_go).map { |r| r.attributes.slice(*columns) }, rows(stepwise).map { |r| r.attributes.slice(*columns) }
  end

  test "a late hours entry for a settled date does not change the settled row" do
    @source.seconds = { D[1] => 100 }
    settle(Time.utc(2026, 11, 3, 12))
    assert_equal [ 0, 0 ], rows.map(&:bonus_bps)
    @source.seconds = { D[1] => 5000 }
    settle(Time.utc(2026, 11, 4, 12))
    assert_equal 100, rows.first.raw_seconds
    assert_not rows.first.quick_met
    assert_equal 3, rows.count
  end

  test "an entry inside the grace period still lands on the day" do
    @source.seconds = { D[1] => 900 }
    # Hours for Nov 1 arrive at 05:00 UTC Nov 2 (grace not over); settlement at 06:00 sees them.
    settle(Time.utc(2026, 11, 2, 5, 0, 0))
    assert_equal 0, rows.count
    settle(Time.utc(2026, 11, 2, 6, 0, 0))
    assert rows.first.quick_met
  end

  test "899 seconds does not qualify and 900 does" do
    @source.seconds = { D[1] => 899, D[2] => 900 }
    settle(Time.utc(2026, 11, 3, 12))
    assert_equal [ false, true ], rows.map(&:quick_met)
  end

  test "the user's time zone decides the day boundary" do
    kiritimati = build_user(time_zone: "Pacific/Kiritimati", created_on: Date.new(2026, 10, 31))
    pago = build_user(time_zone: "Pacific/Pago_Pago", created_on: Date.new(2026, 11, 1))
    # Nov 1 ends 2026-11-01 10:00 UTC (+14) plus 6h grace = 16:00 UTC; for -11 it ends Nov 2 11:00 UTC + 6 = 17:00 UTC.
    instant = Time.utc(2026, 11, 2, 0, 0, 0)
    assert_equal 1, settle(instant, user: kiritimati).size
    assert_equal 0, settle(instant, user: pago).size
    assert_equal 1, settle(Time.utc(2026, 11, 2, 17, 0, 0), user: pago).size
  end

  test "DST: the 25 hour day settles at the right instant and the next day follows" do
    user = build_user(time_zone: "America/New_York", created_on: Date.new(2026, 11, 1))
    # created_at is Nov 1 12:00 UTC = 08:00 EDT: Nov 1 local. Nov 1 settles at Nov 2 11:00 UTC.
    assert_empty settle(Time.utc(2026, 11, 2, 10, 59, 59), user: user)
    assert_equal [ D[1] ], settle(Time.utc(2026, 11, 2, 11, 0, 0), user: user).map(&:local_date)
    # Nov 2 settles 24h later (EST all day).
    assert_empty settle(Time.utc(2026, 11, 3, 10, 59, 59), user: user)
    assert_equal [ D[2] ], settle(Time.utc(2026, 11, 3, 11, 0, 0), user: user).map(&:local_date)
  end

  test "DST: spring forward 2027-03-14" do
    user = build_user(time_zone: "America/New_York", created_on: Date.new(2027, 3, 14))
    assert_empty Game::Settle.call(user, through: Time.utc(2027, 3, 15, 9, 59, 59), source: @source)
    assert_equal [ Date.new(2027, 3, 14) ], Game::Settle.call(user, through: Time.utc(2027, 3, 15, 10, 0, 0), source: @source).map(&:local_date)
  end

  test "a blank or invalid zone settles on UTC days" do
    [ nil, "" ].each do |zone|
      user = build_user
      user.update_columns(time_zone: zone)
      assert_equal [ D[1] ], settle(Time.utc(2026, 11, 2, 6), user: user).map(&:local_date)
    end
  end

  test "changing zone does not rewrite settled rows" do
    @source.seconds = quick_days(D[1]..D[3])
    settle(Time.utc(2026, 11, 3, 12))
    before = rows.map(&:attributes)
    @user.update_columns(time_zone: "Pacific/Kiritimati")
    settle(Time.utc(2026, 11, 4, 12))
    assert_equal before, rows.first(before.size).map(&:attributes)
  end

  test "settling asks the source once for the whole range and passes the user" do
    @source.seconds = quick_days(D[1]..D[5])
    settle(Time.utc(2026, 11, 6, 12))
    assert_equal [ D[1]..D[5] ], @source.requests
  end

  test "nothing is asked of the source when nothing is due" do
    settle(Time.utc(2026, 11, 1, 13))
    assert_empty @source.requests
  end

  test "through must be an instant" do
    assert_raises(ArgumentError) { Game::Settle.call(@user, through: Date.new(2026, 11, 5), source: @source) }
  end

  test "a user created after the instant has nothing to settle" do
    assert_empty settle(Time.utc(2026, 10, 20))
  end

  test "Game::Settle.all settles every user and counts, tolerating a failing user" do
    user_ids = [ @user.id, build_user.id ]
    broken = Object.new
    def broken.seconds_by_date(*) = raise("boom")
    counts = Game::Settle.all(through: Time.utc(2026, 11, 3, 12), source: StubHoursSource.new)
    assert_operator counts[:days], :>=, 4
    assert_equal 0, counts[:errors]
    assert(user_ids.all? { |id| DailyResult.where(user_id: id).exists? })

    failing = Game::Settle.all(through: Time.utc(2026, 12, 3, 12), source: broken)
    assert_operator failing[:errors], :>=, 2
  end

  test "an explicitly set hours source is used" do
    Game::HoursSource.current = @source
    @source.seconds = { D[1] => 900 }
    Game::Settle.call(@user, through: Time.utc(2026, 11, 2, 12))
    assert_equal 500, rows.first.bonus_bps
  ensure
    Game::HoursSource.reset!
  end
end
