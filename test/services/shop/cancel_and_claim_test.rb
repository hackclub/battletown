require "test_helper"
require_relative "../../support/shop_helper"

class Shop::CancelAndClaimTest < ActiveSupport::TestCase
  include ShopTestHelper

  setup do
    @user = verified!(build_user)
    @other = verified!(build_user)
    @admin = admin_user
    @original_env = ENV["ADMIN_HCA_UIDS"]
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    give_coins(@user, 100)
    @order = buy(@user, "tshirt", key: "o1")
  end

  teardown { @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env }

  test "the owner cancels a requested order and gets one refund entry" do
    Shop::Cancel.call(order: @order, by: @user)
    assert_predicate @order.reload, :cancelled?
    assert_not_nil @order.cancelled_at
    assert_equal 100, Coins::Balance.total(@user)
    refund = CoinTransaction.where(user: @user, kind: "refund")
    assert_equal [ 50 ], refund.map(&:amount)
    assert_equal [ "Order", @order.id ], [ refund.first.reference_type, refund.first.reference_id ]
  end

  test "cancelling twice refunds exactly once" do
    2.times { Shop::Cancel.call(order: @order, by: @user) }
    Shop::Cancel.call(order: Order.find(@order.id), by: @admin)
    assert_equal 1, CoinTransaction.where(user: @user, kind: "refund").count
    assert_equal 100, Coins::Balance.total(@user)
  end

  test "an admin can cancel anyone's requested order and it refunds" do
    Shop::Cancel.call(order: @order, by: @admin)
    assert_predicate @order.reload, :cancelled?
    assert_equal 100, Coins::Balance.total(@user)
  end

  test "someone else cannot cancel it" do
    assert_raises(Shop::NotCancellable) { Shop::Cancel.call(order: @order, by: @other) }
    assert_predicate @order.reload, :requested?
    assert_equal 50, Coins::Balance.total(@user)
  end

  test "a fulfilled order cannot be cancelled" do
    Shop::Fulfill.call(order: @order, by: @admin)
    assert_raises(Shop::NotCancellable) { Shop::Cancel.call(order: @order, by: @user) }
    assert_predicate @order.reload, :fulfilled?
    assert_equal 0, CoinTransaction.where(kind: "refund").count
  end

  test "refunded coins can be spent again" do
    Shop::Cancel.call(order: @order, by: @user)
    buy(@user, "tshirt", key: "o2")
    assert_equal 50, Coins::Balance.total(@user)
  end

  test "fulfilling is idempotent, keeps the first timestamp and is admin only" do
    assert_raises(Shop::NotFulfillable) { Shop::Fulfill.call(order: @order, by: @user) }
    Shop::Fulfill.call(order: @order, by: @admin)
    first = @order.reload.fulfilled_at
    assert_predicate @order, :fulfilled?
    assert_not_nil first
    travel 1.hour do
      Shop::Fulfill.call(order: Order.find(@order.id), by: @admin)
    end
    assert_equal first, @order.reload.fulfilled_at
  end

  test "a cancelled order cannot be fulfilled" do
    Shop::Cancel.call(order: @order, by: @user)
    assert_raises(Shop::NotFulfillable) { Shop::Fulfill.call(order: @order, by: @admin) }
    assert_predicate @order.reload, :cancelled?
  end

  # --- the free sticker ---

  test "the sticker is claimed once per user, costs nothing and works unverified" do
    newcomer = build_user
    order = Shop::ClaimSticker.call(user: newcomer)
    assert_equal [ "signup_sticker", "requested", 0, "signup_sticker" ], [ order.kind, order.status, order.coins, order.prize_key ]
    assert_equal 0, CoinTransaction.where(user: newcomer).count
    assert_raises(Shop::AlreadyClaimed) { Shop::ClaimSticker.call(user: newcomer) }
    assert_equal 1, Order.where(user: newcomer).count
    assert_equal 0, Order.where(user: @other).count, "claiming is per user"
  end

  test "the owner cannot cancel their sticker (they could never claim another), an admin can, and nothing is refunded" do
    order = Shop::ClaimSticker.call(user: @user)
    assert_raises(Shop::NotCancellable) { Shop::Cancel.call(order: order, by: @user) }
    Shop::Cancel.call(order: order, by: @admin)
    assert_predicate order.reload, :cancelled?
    assert_equal 0, CoinTransaction.where(user: @user, kind: "refund").count
    assert_raises(Shop::AlreadyClaimed) { Shop::ClaimSticker.call(user: @user) }
  end
end
