require "test_helper"
require_relative "../../support/shop_helper"

class Shop::PurchaseTest < ActiveSupport::TestCase
  include ShopTestHelper

  setup { @user = build_user }

  test "a verified user with enough coins gets an order and one ledger debit, referencing the order" do
    verified!(@user)
    give_coins(@user, 80)
    order = buy(@user, "tshirt", key: "k1")

    assert_predicate order, :persisted?
    assert_equal [ "purchase", "requested", 50, "tshirt", "Battletown T-shirt" ], [ order.kind, order.status, order.coins, order.prize_key, order.prize_name ]
    assert_equal 30, Coins::Balance.total(@user)
    debit = CoinTransaction.find_by(user: @user, kind: "purchase")
    assert_equal(-50, debit.amount)
    assert_equal [ "Order", order.id ], [ debit.reference_type, debit.reference_id ]
  end

  # The page shows a price and the form sends it back as `expected_coins`: a staff price change in between is refused with a
  # friendly message instead of charging more (or less) than the buyer agreed to.
  test "the price the buyer saw must still be the price: a change in between is refused and nothing is written" do
    verified!(@user)
    give_coins(@user, 500)
    ShopItem.find_by!(key: "tshirt").update!(coins: 80)
    error = assert_raises(Shop::PriceChanged) { Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k-price", expected_coins: 50) }
    assert_match(/price changed/i, error.message)
    assert_equal 0, Order.count
    assert_equal 500, Coins::Balance.total(@user)

    order = Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k-price", expected_coins: 80)
    assert_equal 80, order.coins
    assert_equal 420, Coins::Balance.total(@user)
    assert_equal order, Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k-price", expected_coins: 50), "a repeat of an order that exists never re-checks the price"
  end

  test "no expected price means no check (callers that never showed a price)" do
    verified!(@user)
    give_coins(@user, 500)
    assert_equal 50, Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "k-none").coins
  end

  test "a purchase key cannot take the name of the free sticker's key, which would lock the person out of their sticker" do
    verified!(@user)
    give_coins(@user, 500)
    assert_raises(Shop::KeyConflict) { Shop::Purchase.call(user: @user, prize_key: "tshirt", idempotency_key: "signup_sticker") }
    assert_equal 0, Order.count
    assert_equal "signup_sticker", Shop::ClaimSticker.call(user: @user).prize_key
  end

  test "an unverified user cannot buy, even with coins, and nothing is written" do
    give_coins(@user, 500)
    assert_equal 0, Shop::Spendable.balance(@user)
    assert_raises(Shop::NotVerified) { buy(@user) }
    assert_equal 0, Order.count
    assert_equal 500, Coins::Balance.total(@user)
  end

  test "not enough coins is refused, one coin short too, and nothing is written" do
    verified!(@user)
    give_coins(@user, 49)
    error = assert_raises(Shop::InsufficientCoins) { buy(@user, "tshirt") }
    assert_match(/enough coins/, error.message)
    assert_equal 0, Order.count
    assert_equal 49, Coins::Balance.total(@user)
  end

  test "exactly the price works and leaves zero" do
    verified!(@user)
    give_coins(@user, 50)
    buy(@user, "tshirt")
    assert_equal 0, Coins::Balance.total(@user)
    assert_raises(Shop::InsufficientCoins) { buy(@user, "custom_sticker") }
  end

  test "the same idempotency key returns the same order and charges once" do
    verified!(@user)
    give_coins(@user, 100)
    first = buy(@user, "tshirt", key: "double")
    second = buy(@user, "tshirt", key: "double")
    assert_equal first.id, second.id
    assert_equal 1, Order.count
    assert_equal 1, CoinTransaction.where(user: @user, kind: "purchase").count
    assert_equal 50, Coins::Balance.total(@user)
  end

  test "reusing a key for another item is a conflict, not a second charge" do
    verified!(@user)
    give_coins(@user, 100)
    buy(@user, "tshirt", key: "reuse")
    assert_raises(Shop::KeyConflict) { buy(@user, "poster", key: "reuse") }
    assert_equal 50, Coins::Balance.total(@user)
  end

  test "a replay still returns the order if the user was unverified in the meantime" do
    verified!(@user)
    give_coins(@user, 100)
    order = buy(@user, "tshirt", key: "again")
    @user.update_columns(verification_status: "needs_submission")
    assert_equal order.id, buy(@user, "tshirt", key: "again").id
  end

  test "an unknown item and the free sticker are refused with friendly errors" do
    verified!(@user)
    give_coins(@user, 100)
    assert_raises(Shop::UnknownPrize) { buy(@user, "nope") }
    assert_raises(Shop::UnknownPrize) { buy(@user, "") }
    assert_raises(Shop::FreeItem) { buy(@user, "signup_sticker") }
    assert_equal 0, Order.count
  end

  test "a blank or oversized key is refused" do
    verified!(@user)
    give_coins(@user, 100)
    assert_raises(Shop::KeyConflict) { buy(@user, "tshirt", key: "") }
    assert_raises(Shop::KeyConflict) { buy(@user, "tshirt", key: "x" * 101) }
  end

  test "pending and ineligible users are locked too" do
    give_coins(@user, 500)
    %w[pending ineligible needs_submission].each do |status|
      @user.update_columns(verification_status: status)
      assert_raises(Shop::NotVerified, status) { buy(@user) }
    end
  end

  test "Spendable is the total when verified and zero otherwise" do
    give_coins(@user, 70)
    assert_equal 0, Shop::Spendable.balance(@user)
    assert Shop::Spendable.locked?(@user)
    verified!(@user)
    assert_equal 70, Shop::Spendable.balance(@user)
    assert Shop::Spendable.unlocked?(@user)
  end
end
