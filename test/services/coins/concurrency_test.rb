require "test_helper"
require_relative "../../support/coins_helper"

# Real threads on real connections, so these tests cannot run inside a rolled-back transaction. Each test creates its
# own user and deletes it (and so its rows, by cascade) at the end.
class Coins::ConcurrencyTest < ActiveSupport::TestCase
  include CoinsHelper

  self.use_transactional_tests = false

  setup { @user = build_user(created_on: Date.new(2026, 11, 1)) }
  teardown { User.where(id: @user.id).delete_all }

  # Runs the blocks at the same moment on separate connections; returns each outcome as [:ok, value] or [:error, exception].
  def race(*blocks)
    gate = Queue.new
    ready = Queue.new
    threads = blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          gate.pop
          [ :ok, block.call ]
        rescue StandardError => error
          [ :error, error ]
        end
      end
    end
    blocks.size.times { Timeout.timeout(20) { ready.pop } }
    blocks.size.times { gate << true }
    threads.map(&:value)
  end

  test "two simultaneous debits of the whole balance: exactly one succeeds and the balance is never negative" do
    Coins::Ledger.credit(user: @user, amount: 10, kind: "refund", idempotency_key: "seed")
    outcomes = race(
      -> { Coins::Ledger.debit(user: User.find(@user.id), amount: 10, kind: "purchase", idempotency_key: "buy-1") },
      -> { Coins::Ledger.debit(user: User.find(@user.id), amount: 10, kind: "purchase", idempotency_key: "buy-2") }
    )
    assert_equal 1, outcomes.count { |kind, _| kind == :ok }
    failure = outcomes.find { |kind, _| kind == :error }
    assert_kind_of Coins::InsufficientBalance, failure.last
    assert_equal 0, Coins::Balance.total(@user)
  end

  test "several simultaneous debits never overdraw (the pool holds five connections, so at most four threads)" do
    Coins::Ledger.credit(user: @user, amount: 25, kind: "refund", idempotency_key: "seed")
    blocks = 4.times.map do |i|
      -> { Coins::Ledger.debit(user: User.find(@user.id), amount: 10, kind: "purchase", idempotency_key: "buy-#{i}") }
    end
    outcomes = race(*blocks)
    assert_equal 2, outcomes.count { |kind, _| kind == :ok }
    assert_equal 5, Coins::Balance.total(@user)
    assert_operator Coins::Balance.total(@user), :>=, 0
  end

  test "the same debit retried concurrently is applied once" do
    Coins::Ledger.credit(user: @user, amount: 30, kind: "refund", idempotency_key: "seed")
    outcomes = race(*4.times.map { -> { Coins::Ledger.debit(user: User.find(@user.id), amount: 10, kind: "purchase", idempotency_key: "same") } })
    assert(outcomes.all? { |kind, _| kind == :ok })
    assert_equal 1, outcomes.map { |_, row| row.id }.uniq.size
    assert_equal 20, Coins::Balance.total(@user)
  end

  test "approving the same ship from two threads credits exactly once" do
    source = StubHoursSource.new({ Date.new(2026, 11, 1) => 3600, Date.new(2026, 11, 2) => 3600 })
    ship = [ "Ship", 4242 ]
    call = lambda do
      Coins::ApproveShip.call(user: User.find(@user.id), ship_reference: ship, approved_seconds: 7200,
                              window_dates: Date.new(2026, 11, 1)..Date.new(2026, 11, 2), source: source, now: Time.utc(2026, 11, 10, 12))
    end
    outcomes = race(call, call, call)

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    assert_equal 1, outcomes.count { |_, result| !result.already_approved }
    assert_equal 1, CoinTransaction.where(user_id: @user.id, kind: "ship_approval").count
    assert_equal 1, CoinTransaction.where(user_id: @user.id, kind: "streak_bonus").count
    # 2h = 20 base; bonus 5% + 7% of 10 coins each = 1.2, floored with the base: 21
    assert_equal 21, Coins::Balance.total(@user)
  end

  test "settling from two threads writes each day once" do
    source = StubHoursSource.new(quick_days(Date.new(2026, 11, 1)..Date.new(2026, 11, 6)))
    settle = -> { Game::Settle.call(User.find(@user.id), through: Time.utc(2026, 11, 8, 12), source: source) }
    outcomes = race(settle, settle, settle)

    assert(outcomes.all? { |kind, _| kind == :ok }, outcomes.map(&:last).inspect)
    assert_equal 7, outcomes.sum { |_, written| written.size }
    # Nov 7 had no coding: the freeze keeps the streak at 6.
    assert_equal [ 1, 2, 3, 4, 5, 6, 6 ], DailyResult.where(user_id: @user.id).order(:local_date).map(&:streak_15)
  end
end
