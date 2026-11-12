require "test_helper"
require_relative "../support/orders_helper"
require_relative "../support/admin_sign_in"
require_relative "../support/notifications_helper"

# Abuse and safety around orders: the per-person throttle on placing them, the cap on orders waiting for the team, and the
# privacy of tracking numbers in the request log.
class OrderAbuseLimitsTest < ActionDispatch::IntegrationTest
  include OrdersTestHelper
  include AdminSignIn
  include NotificationsHelper

  WINDOW_START = Time.utc(2030, 1, 1, 12, 0, 0)

  setup do
    setup_orders_world(coins: 100_000)
    [ @buyer, @other ].each { |user| user.update_columns(onboarded_at: Time.utc(2026, 11, 1), onboarding_step: 4) }
    verified!(@other)
    give_coins(@other, 100_000)
  end

  teardown do
    teardown_orders_world
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
  end

  def throttled
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    travel_to(WINDOW_START) { yield }
  end

  def place(key, as: @buyer) = post_order_as(as, prize_key: "custom_sticker", key: key)

  test "placing orders is limited per person per hour (default 10); a bad request counts too, another person is unaffected" do
    assert_equal 10, Orders::Config.current.orders_per_hour
    throttled do
      with_orders_config(max_open_requested: 100) do
        sign_in_as @buyer
        10.times { |i| place("limit-#{i}-aaaaaaaaaa") }
        assert_response :redirect
        assert_equal 10, Order.where(user: @buyer).count
        place("limit-extra-aaaaaaa")
        assert_response :too_many_requests
        assert_equal 10, Order.where(user: @buyer).count

        delete logout_path
        sign_in_as @other
        place("other-1-aaaaaaaaaaa", as: @other)
        assert_not_equal 429, response.status
        assert_equal 1, Order.where(user: @other).count
      end
    end
  end

  test "the order limit follows the configuration" do
    throttled do
      with_orders_config(orders_per_hour: 2, max_open_requested: 100) do
        sign_in_as @buyer
        2.times { |i| place("cfg-#{i}-aaaaaaaaaaaa") }
        place("cfg-extra-aaaaaaaaaa")
        assert_response :too_many_requests
      end
    end
  end

  test "the limit is per person, not per address: two people behind one address don't share it" do
    throttled do
      with_orders_config(orders_per_hour: 1, max_open_requested: 100) do
        sign_in_as @buyer
        place("addr-a-aaaaaaaaaaaaa")
        place("addr-b-aaaaaaaaaaaaa")
        assert_response :too_many_requests
        delete logout_path
        sign_in_as @other
        place("addr-c-aaaaaaaaaaaaa")
        assert_not_equal 429, response.status
      end
    end
  end

  test "path variations do not get around the order throttle" do
    throttled do
      with_orders_config(orders_per_hour: 1, max_open_requested: 100) do
        sign_in_as @buyer
        place("var-a-aaaaaaaaaaaaaa")
        post "/shop/orders/", params: { prize_key: "custom_sticker", idempotency_key: "var-b-aaaaaaaaaaaaaa" }
        assert_response :too_many_requests
        post "/shop/orders.json", params: { prize_key: "custom_sticker", idempotency_key: "var-c-aaaaaaaaaaaaaa" }
        assert_response :too_many_requests
      end
    end
  end

  test "reading orders is not throttled by the order limit" do
    throttled do
      with_orders_config(orders_per_hour: 1) do
        sign_in_as @buyer
        5.times { get orders_path }
        assert_response :success
      end
    end
  end

  test "the cap on orders waiting for the team gives a friendly error through the page" do
    sign_in_as @buyer
    Orders::Config.current.max_open_requested.times { |i| place("cap-#{i}-aaaaaaaaaaaaaa") }
    place("cap-extra-aaaaaaaaaaaaa")
    follow_redirect!
    assert_select ".flash--alert", /orders waiting for the team/
    # once the team sends one, there is room again
    shipping = Order.where(user: @buyer).first
    Orders::Ship.call(order: shipping, by: @staff, as: :staff)
    place("cap-after-aaaaaaaaaaaaa")
    assert_equal Orders::Config.current.max_open_requested + 1, Order.where(user: @buyer).count
  end

  test "tracking numbers, notes and reasons stay out of the request log" do
    ENV["ADMIN_HCA_UIDS"] = @staff.hca_uid
    order = order_for(address: true)
    sign_in_as @staff
    logs = capture_logs do
      patch ship_admin_order_path(order), params: { tracking: { carrier: "other", number: "1Z999AA10123456784", label: "Secret courier" }, note: "Private staff words" }
      post note_admin_order_path(order), params: { note: "Another private staff line" }
      patch tracking_admin_order_path(order), params: { tracking: { carrier: "ups", number: "1Z999AA10123456999" } }
      get admin_orders_path(q: "shirt")
    end
    assert_predicate order.reload, :shipped?
    [ "1Z999AA10123456784", "1Z999AA10123456999", "Secret courier", "Private staff words", "Another private staff line" ].each do |secret|
      assert_not_includes logs, secret
    end
    assert_includes logs, "[FILTERED]"
  end

  test "the buyer's page request log has no tracking number, and the filter list covers tracking parameters" do
    order = order_in("shipped")
    sign_in_as @buyer
    logs = capture_logs { get order_path(order) }
    assert_not_includes logs, "1Z999AA10123456784"
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal({ "tracking" => "[FILTERED]", "tracking_number" => "[FILTERED]", "tracking_label" => "[FILTERED]" },
                 filtered.filter({ "tracking" => { "number" => "x" }, "tracking_number" => "x", "tracking_label" => "x" }))
  end

  test "the CSV export request log has no contact data and no tracking number either" do
    ENV["ADMIN_HCA_UIDS"] = @staff.hca_uid
    order_in("shipped")
    sign_in_as @staff
    logs = capture_logs { post export_admin_orders_path, params: { include_contact: "1" } }
    [ "1Z999AA10123456784", "Pat Buyer", "U0ORDERBUY" ].each { |secret| assert_not_includes logs, secret }
  end
end
