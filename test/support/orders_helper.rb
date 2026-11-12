require "test_helper"
require_relative "shop_helper"

# Helpers for the order lifecycle tests: a buyer with coins, a staff member (an admin through ADMIN_HCA_UIDS), and orders put in
# any status through the real services.
module OrdersTestHelper
  include ShopTestHelper

  def setup_orders_world(coins: 500)
    @buyer = verified!(build_user)
    @buyer.update_columns(slack_id: "U0ORDERBUY", onboarded_at: Time.utc(2026, 11, 1), onboarding_step: 4, display_name: "Pat Buyer")
    @staff = build_user
    @staff.update_columns(display_name: "Sam Staff")
    @other = verified!(build_user)
    @original_admin_uids = ENV["ADMIN_HCA_UIDS"]
    ENV["ADMIN_HCA_UIDS"] = @staff.hca_uid
    give_coins(@buyer, coins)
  end

  def teardown_orders_world
    @original_admin_uids.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admin_uids
  end

  # `address: true` gives a posted item the shipping address checkout would have copied in (needed before staff can ship it).
  def order_for(user = @buyer, prize: "tshirt", address: false)
    buy(user, prize, address: address)
  end

  # `Ship` gives a posted order the address checkout would have copied in first (the lifecycle tests are not about addresses; the
  # address tests build their own orders and pass `address_override_reason:` or leave the address off on purpose).
  def staff_do(service, order, **options)
    give_address!(order) if service == "Ship" && !options.key?(:address_override_reason) && order.requires_shipping? && !OrderAddress.exists?(order_id: order.id)
    "Orders::#{service}".constantize.call(order: order, by: @staff, as: :staff, **options)
  end

  # An order brought to `status` through the services, the way it happens for real.
  def order_in(status, user = @buyer, prize: "tshirt")
    order = order_for(user, prize: prize)
    case status
    when "requested" then nil
    when "on_hold" then staff_do("Hold", order)
    when "shipped" then staff_do("Ship", order, tracking: { carrier: "ups", number: "1Z999AA10123456784" })
    when "fulfilled" then staff_do("Fulfil", order)
    when "cancelled" then staff_do("Cancel", order, reason_code: "buyer_request")
    when "refunded"
      staff_do("Ship", order)
      staff_do("Refund", order, reason_code: "other")
    else raise ArgumentError, status
    end
    order.reload
  end

  # Runs the block with some Orders::Config values changed (the memoised config is put back afterwards).
  def with_orders_config(**changes)
    original = Orders::Config.current
    Orders::Config.instance_variable_set(:@current, original.with(**changes))
    yield
  ensure
    Orders::Config.instance_variable_set(:@current, original)
  end

  def refunds_for(user = @buyer) = CoinTransaction.where(user_id: user.id, kind: "refund")
end
