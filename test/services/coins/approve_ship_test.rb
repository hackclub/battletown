require "test_helper"
require_relative "../../support/coins_helper"

class Coins::ApproveShipTest < ActiveSupport::TestCase
  include CoinsHelper

  D = ->(day) { Date.new(2026, 11, day) }
  NOW = Time.utc(2026, 11, 20, 12)

  setup do
    @user = build_user(created_on: Date.new(2026, 11, 1))
    @source = StubHoursSource.new
    @ship = Struct.new(:id) { def self.name = "Ship" }.new(7)
  end

  def approve(approved_seconds:, dates:, ship: @ship, **extra)
    Coins::ApproveShip.call(user: @user, ship_reference: ship, approved_seconds: approved_seconds, window_dates: dates, source: @source, now: NOW, **extra)
  end

  def entries = CoinTransaction.where(user_id: @user.id).order(:id)

  test "writes one ship_approval and one streak_bonus entry from settled bonus_bps" do
    # Nov 1 to Nov 3: streak days 1, 2, 3 at 5%, 7%, 8.1% of an hour each.
    @source.seconds = { D[1] => 3600, D[2] => 3600, D[3] => 3600 }
    result = approve(approved_seconds: 3 * 3600, dates: D[1]..D[3])

    assert_equal 30, result.base_coins
    # 10 * (0.05 + 0.07 + 0.081) = 2.01 coins of bonus, floored together with the base: 32
    assert_equal 2, result.bonus_coins
    assert_equal 32, result.total_coins
    assert_equal [ "ship_approval", "streak_bonus" ], entries.map(&:kind)
    assert_equal [ 30, 2 ], entries.map(&:amount)
    assert_equal [ "ship_approval:Ship:7", "streak_bonus:Ship:7" ], entries.map(&:idempotency_key)
    assert_equal [ [ "Ship", 7 ] ] * 2, entries.map { |e| [ e.reference_type, e.reference_id ] }
    assert_equal 32, Coins::Balance.total(@user)
    assert_not result.already_approved
    assert_empty result.unsettled_dates
  end

  test "approving the same ship twice credits once" do
    @source.seconds = { D[1] => 4 * 3600 }
    first = approve(approved_seconds: 4 * 3600, dates: [ D[1] ])
    second = approve(approved_seconds: 4 * 3600, dates: [ D[1] ])
    assert second.already_approved
    assert_equal 42, first.total_coins # 40 base, 2.0 bonus
    assert_equal first.total_coins, second.total_coins
    assert_equal first.base_entry.id, second.base_entry.id
    assert_equal 2, entries.count
    assert_equal first.total_coins, Coins::Balance.total(@user)
  end

  test "approving twice with different numbers still credits once, with the first numbers" do
    @source.seconds = { D[1] => 7200 }
    approve(approved_seconds: 3600, dates: [ D[1] ])
    approve(approved_seconds: 7200, dates: [ D[1] ])
    assert_equal 10 + 0, entries.where(kind: "ship_approval").sum(:amount)
  end

  test "different ships are independent" do
    @source.seconds = { D[1] => 4 * 3600, D[2] => 4 * 3600 }
    approve(approved_seconds: 4 * 3600, dates: [ D[1] ])
    other = Struct.new(:id) { def self.name = "Ship" }.new(8)
    approve(approved_seconds: 4 * 3600, dates: [ D[2] ], ship: other)
    assert_equal 4, entries.count
  end

  test "a day with no streak bonus writes only the ship_approval entry" do
    @source.seconds = { D[1] => 600 } # under 15 minutes: no bonus
    result = approve(approved_seconds: 600, dates: [ D[1] ])
    assert_equal [ 1, 0 ], [ result.base_coins, result.bonus_coins ]
    assert_equal [ "ship_approval" ], entries.map(&:kind)
    assert_nil result.bonus_entry
  end

  test "a ship worth less than one coin writes nothing" do
    @source.seconds = { D[1] => 100 }
    result = approve(approved_seconds: 100, dates: [ D[1] ])
    assert_equal 0, result.total_coins
    assert_equal 0, entries.count
  end

  test "deflation applies after 6 hours since the previous ship" do
    @source.seconds = { D[1] => 5 * 3600, D[2] => 5 * 3600 }
    result = approve(approved_seconds: 10 * 3600, dates: D[1]..D[2])
    # 6h at 10 + 4h at 8 = 92 base
    assert_equal 92, result.base_coins
    assert_equal 4 * 3600, result.payout.per_date.values.sum { |row| row[:deflated_seconds] }
  end

  test "hours already counted before the window deflate sooner" do
    @source.seconds = { D[1] => 3600 }
    result = approve(approved_seconds: 3600, dates: [ D[1] ], hours_since_previous_ship_before_window: 6)
    assert_equal 8, result.base_coins
  end

  test "dates that are not settled yet earn no bonus and are reported" do
    @source.seconds = { D[19] => 3600, D[20] => 3600 }
    # NOW is Nov 20 12:00 UTC: Nov 19 is settled (settled at Nov 20 06:00), Nov 20 is not.
    result = approve(approved_seconds: 7200, dates: [ D[19], D[20] ])
    assert_equal [ D[20] ], result.unsettled_dates
    assert_equal 20, result.base_coins
    assert_equal 0, DailyResult.where(user_id: @user.id, local_date: D[20]).count
    assert_equal 1, DailyResult.where(user_id: @user.id, local_date: D[19]).count
  end

  test "approval settles the needed days first" do
    @source.seconds = quick_days(D[1]..D[5], seconds: 3600)
    assert_equal 0, DailyResult.where(user_id: @user.id).count
    approve(approved_seconds: 5 * 3600, dates: D[1]..D[5])
    assert_operator DailyResult.where(user_id: @user.id).count, :>=, 5
  end

  test "dates before the account existed earn no bonus and are not reported as unsettled" do
    @source.seconds = { Date.new(2026, 10, 25) => 3600 }
    result = approve(approved_seconds: 3600, dates: [ Date.new(2026, 10, 25) ])
    assert_equal [ 10, 0 ], [ result.base_coins, result.bonus_coins ]
    assert_empty result.unsettled_dates
  end

  test "approved time with no coded time in the window is refused and writes nothing" do
    assert_raises(Coins::ShipPayout::NothingToAllocate) { approve(approved_seconds: 3600, dates: [ D[1] ]) }
    assert_equal 0, entries.count
  end

  test "arguments are checked" do
    assert_raises(ArgumentError) { approve(approved_seconds: 100, dates: []) }
    assert_raises(ArgumentError) { approve(approved_seconds: 100, dates: [ D[1] ], ship: nil) }
  end

  test "a [type, id] pair works as the reference" do
    @source.seconds = { D[1] => 3600 }
    result = approve(approved_seconds: 3600, dates: [ D[1] ], ship: [ "Ship", 99 ])
    assert_equal "ship_approval:Ship:99", result.base_entry.idempotency_key
  end

  test "a late hours entry after settlement does not change the bonus, but is counted as coded time" do
    @source.seconds = { D[1] => 900 }
    Game::Settle.call(@user, through: NOW, source: @source)
    @source.seconds = { D[1] => 3600 }
    result = approve(approved_seconds: 3600, dates: [ D[1] ])
    # The settled day had 900 seconds (day 1, 5%): its bonus_bps still applies to the full coded hour.
    assert_equal 500, DailyResult.find_by(user_id: @user.id, local_date: D[1]).bonus_bps
    assert_equal [ 10, 0 ], [ result.base_coins, result.bonus_coins ] # 0.5 coin of bonus floors away
  end
end
