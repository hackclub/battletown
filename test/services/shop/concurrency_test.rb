require "test_helper"
require_relative "../../support/shop_helper"

# Real threads on real connections, so these cannot run inside a rolled-back transaction. Each test makes its own
# user and deletes it (and its rows, by cascade) at the end.
class Shop::ConcurrencyTest < ActiveSupport::TestCase
  include ShopTestHelper

  self.use_transactional_tests = false

  setup do
    @user = verified!(build_user)
    @admin_uid = ENV["ADMIN_HCA_UIDS"]
  end
  teardown { User.where(id: @user.id).delete_all }

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

  test "two different buys with balance for one: one succeeds, the other is refused, balance never negative" do
    give_coins(@user, 50)
    outcomes = race(
      -> { Shop::Purchase.call(user: User.find(@user.id), prize_key: "tshirt", idempotency_key: "race-a") },
      -> { Shop::Purchase.call(user: User.find(@user.id), prize_key: "tshirt", idempotency_key: "race-b") }
    )
    assert_equal 1, outcomes.count { |kind, _| kind == :ok }
    assert_kind_of Shop::InsufficientCoins, outcomes.find { |kind, _| kind == :error }.last
    assert_equal 1, Order.where(user_id: @user.id).count
    assert_equal 0, Coins::Balance.total(@user)
  end

  test "the same key submitted twice at once makes one order and one charge" do
    give_coins(@user, 200)
    outcomes = race(
      -> { Shop::Purchase.call(user: User.find(@user.id), prize_key: "tshirt", idempotency_key: "same") },
      -> { Shop::Purchase.call(user: User.find(@user.id), prize_key: "tshirt", idempotency_key: "same") }
    )
    assert_equal [ :ok, :ok ], outcomes.map(&:first)
    assert_equal 1, outcomes.map { |_, order| order.id }.uniq.size
    assert_equal 1, Order.where(user_id: @user.id).count
    assert_equal 150, Coins::Balance.total(@user)
  end

  test "cancelling twice at once refunds once" do
    give_coins(@user, 50)
    order = Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "to-cancel")
    outcomes = race(
      -> { Orders::Cancel.call(order: Order.find(order.id), by: User.find(@user.id)) },
      -> { Orders::Cancel.call(order: Order.find(order.id), by: User.find(@user.id)) }
    )
    assert_equal [ :ok, :ok ], outcomes.map(&:first)
    assert_equal 1, CoinTransaction.where(user_id: @user.id, kind: "refund").count
    assert_equal 50, Coins::Balance.total(@user)
  end

  test "claiming the sticker twice at once makes one order" do
    outcomes = race(
      -> { Shop::ClaimSticker.call(user: User.find(@user.id)) },
      -> { Shop::ClaimSticker.call(user: User.find(@user.id)) }
    )
    assert_equal 1, outcomes.count { |kind, _| kind == :ok }
    assert_kind_of Shop::AlreadyClaimed, outcomes.find { |kind, _| kind == :error }.last
    assert_equal 1, Order.where(user_id: @user.id, kind: "signup_sticker").count
  end
end
