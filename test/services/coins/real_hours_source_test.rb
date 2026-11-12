require "test_helper"
require_relative "../../support/coins_helper"

# Settlement and approval against the real hours ledger (Hours::Totals over HourEntry), with no stub.
class Coins::RealHoursSourceTest < ActiveSupport::TestCase
  include CoinsHelper

  D = ->(day) { Date.new(2026, 11, day) }

  setup { @user = build_user(created_on: Date.new(2026, 11, 1)) }

  def log(date, seconds, key: "t4-#{date}-#{seconds}-#{SecureRandom.hex(3)}")
    HourEntry.create!(user: @user, local_date: date, seconds: seconds, source: "manual", note: "test", idempotency_key: key)
  end

  test "the default hours source is the hours ledger" do
    Game::HoursSource.reset!
    assert_equal Hours::Totals, Game::HoursSource.current
  end

  test "settlement reads real daily seconds, with no source passed" do
    log(D[1], 899)
    log(D[2], 450)
    log(D[2], 450)
    log(D[3], 3600)
    Game::Settle.call(@user, through: Time.utc(2026, 11, 4, 12))
    rows = DailyResult.where(user_id: @user.id).chronological
    assert_equal [ 899, 900, 3600 ], rows.first(3).map(&:raw_seconds)
    assert_equal [ false, true, true ], rows.first(3).map(&:quick_met)
    assert_equal [ 0, 500, 700 ], rows.first(3).map(&:bonus_bps)
  end

  test "an adjustment that lowers a day is netted, and a late entry after settlement does not change the row" do
    log(D[1], 1200)
    HourEntry.create!(user: @user, local_date: D[1], seconds: -600, source: "adjustment", note: "fix", idempotency_key: "adj-1")
    Game::Settle.call(@user, through: Time.utc(2026, 11, 3, 12))
    assert_equal 600, DailyResult.find_by(user_id: @user.id, local_date: D[1]).raw_seconds
    log(D[1], 3000)
    Game::Settle.call(@user, through: Time.utc(2026, 11, 4, 12))
    assert_equal 600, DailyResult.find_by(user_id: @user.id, local_date: D[1]).raw_seconds
  end

  test "approving a ship end to end pays coins from the real ledger, once" do
    log(D[1], 2 * 3600)
    log(D[2], 2 * 3600)
    args = { user: @user, ship_reference: [ "Ship", 1 ], approved_seconds: 4 * 3600, window_dates: D[1]..D[2], now: Time.utc(2026, 11, 10, 12) }
    result = Coins::ApproveShip.call(**args)
    # 40 base; bonus 5% of 20 + 7% of 20 = 2.4 -> total 42
    assert_equal [ 40, 2, 42 ], [ result.base_coins, result.bonus_coins, result.total_coins ]
    assert Coins::ApproveShip.call(**args).already_approved
    assert_equal 42, Coins::Balance.total(@user)
  end
end
