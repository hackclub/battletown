require "test_helper"
require_relative "../../support/shop_helper"

# Staff changing the catalogue (a price, archiving) at the same moment a person buys: whichever wins, the order, the ledger
# debit and the balance agree, and a price the buyer did not agree to is never charged. Real threads on real connections.
class Shop::CatalogueRaceTest < ActiveSupport::TestCase
  include ShopTestHelper

  self.use_transactional_tests = false

  setup do
    @user = verified!(build_user)
    give_coins(@user, 1000)
    @item = ShopItem.find_by!(key: "keychain")
    @original = @item.slice(:coins, :active).symbolize_keys
  end

  teardown do
    User.where(id: @user.id).delete_all
    ShopItem.find_by!(key: "keychain").update!(@original)
    Prize.reload!
  end

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

  def reprice(coins)
    ShopItem.find_by!(key: "keychain").update!(coins: coins)
    Prize.reload!
  end

  def debits = CoinTransaction.where(user_id: @user.id, kind: "purchase")

  test "a price change racing a purchase: the order costs what the buyer saw, or the buyer is told the price changed, never a mix" do
    30.times do |round|
      reprice(30)
      outcomes = race(
        -> { Shop::Purchase.call(user: User.find(@user.id), prize_key: "keychain", idempotency_key: "price-#{round}", expected_coins: 30) },
        -> { reprice(95) }
      )
      kind, purchase = outcomes.first
      if kind == :ok
        assert_equal 30, purchase.coins, "round #{round}: an order made at the shown price"
        assert_equal(-30, debits.find_by!(reference_id: purchase.id).amount, "round #{round}: debit equals the order")
      else
        assert_kind_of Shop::PriceChanged, purchase, "round #{round}"
        assert_not Order.exists?(user_id: @user.id, idempotency_key: "price-#{round}")
      end
    end
    paid = Order.where(user_id: @user.id, kind: "purchase")
    assert_equal paid.sum(:coins), -debits.sum(:amount), "every order has exactly its own debit"
    assert_equal 1000 - paid.sum(:coins), Coins::Balance.total(@user)
    assert_empty paid.where.not(coins: 30)
  end

  test "archiving an item while it is being bought: the order exists with its debit, or the buyer is told it is gone" do
    30.times do |round|
      ShopItem.find_by!(key: "keychain").update!(active: true)
      Prize.reload!
      outcomes = race(
        -> { Shop::Purchase.call(user: User.find(@user.id), prize_key: "keychain", idempotency_key: "arch-#{round}") },
        -> { ShopItem.find_by!(key: "keychain").update!(active: false).tap { Prize.reload! } }
      )
      kind, purchase = outcomes.first
      if kind == :ok
        assert_equal 30, purchase.coins
        assert debits.exists?(reference_id: purchase.id), "round #{round}: an order always has its debit"
      else
        assert_kind_of Shop::ItemUnavailable, purchase, "round #{round}"
      end
    end
    paid = Order.where(user_id: @user.id, kind: "purchase")
    assert_equal paid.count, debits.count
    assert_equal 1000 - paid.sum(:coins), Coins::Balance.total(@user)
    # The orders that were made stay valid after the item was archived: they can still be cancelled for a full refund.
    order = paid.first
    if order
      Orders::Cancel.call(order: order, by: User.find(@user.id), as: :buyer)
      assert_equal order.coins, CoinTransaction.find_by!(user_id: @user.id, kind: "refund", reference_id: order.id).amount
    end
  end
end
