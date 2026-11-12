require "test_helper"
require_relative "../support/shop_helper"

class AdminOrdersTest < ActionDispatch::IntegrationTest
  include ShopTestHelper

  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @buyer = users(:onboarded)
    @buyer.update_columns(slack_id: "U0BUYER123", verification_status: "verified")
    give_coins(@buyer, 200)
    @waiting = buy(@buyer, "tshirt")
    @sticker = Shop::ClaimSticker.call(user: users(:new_user))
    @done = buy(@buyer, "keychain")
    @admin = admin_user
    @done.update_columns(status: "fulfilled", fulfilled_at: Time.current)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def as_admin
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @admin
  end

  test "signed-out visitors and non-admins get a 404 on every orders route, and nothing changes" do
    get admin_orders_path
    assert_response :not_found
    patch fulfill_admin_order_path(@waiting)
    assert_response :not_found
    patch cancel_admin_order_path(@waiting)
    assert_response :not_found

    sign_in_as @buyer
    get admin_orders_path
    assert_response :not_found
    patch fulfill_admin_order_path(@waiting)
    assert_response :not_found
    patch cancel_admin_order_path(@waiting)
    assert_response :not_found
    assert_predicate @waiting.reload, :requested?
    assert_equal 0, CoinTransaction.where(kind: "refund").count
  end

  test "the list shows requested first, in an admin tool, with the person's name, Slack id and verification" do
    as_admin
    get admin_orders_path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only"
    assert_select "#requested-count", text: "2"
    rows = css_select("tbody tr").map { |row| row["id"] }
    assert_equal "order-#{@done.id}", rows.last, "the fulfilled order comes after the requested ones"
    assert_select "#order-#{@waiting.id}", text: /Veteran/
    assert_select "#order-#{@waiting.id}", text: /Slack: U0BUYER123/
    assert_select "#order-#{@waiting.id}", text: /Identity: verified/
    assert_select "#order-#{@sticker.id}", text: /Identity: needs submission/
    assert_select "#order-#{@waiting.id} button", text: "Mark fulfilled"
    assert_select "#order-#{@done.id} button", count: 0
    assert_no_match(/address/i, css_select("tbody").text)
  end

  test "filter by status and kind, and an unknown filter is ignored" do
    as_admin
    get admin_orders_path(status: "fulfilled")
    assert_select "tbody tr", 1
    get admin_orders_path(kind: "signup_sticker")
    assert_select "tbody tr", 1
    assert_select "#order-#{@sticker.id}"
    get admin_orders_path(status: "requested", kind: "purchase")
    assert_select "tbody tr", 1
    get admin_orders_path(status: "'; drop table orders", kind: "zzz")
    assert_select "tbody tr", 3
  end

  test "mark fulfilled sets the time once and is safe to repeat" do
    as_admin
    patch fulfill_admin_order_path(@waiting)
    assert_redirected_to admin_orders_path
    first = @waiting.reload.fulfilled_at
    assert_predicate @waiting, :fulfilled?
    travel 2.hours do
      patch fulfill_admin_order_path(@waiting)
    end
    assert_equal first, @waiting.reload.fulfilled_at
    assert_equal 1, Order.where(status: "fulfilled", id: @waiting.id).count
  end

  test "cancel from the queue refunds once and keeps the filters" do
    as_admin
    before = Coins::Balance.total(@buyer)
    patch cancel_admin_order_path(@waiting, status: "requested")
    assert_redirected_to admin_orders_path(status: "requested")
    follow_redirect!
    assert_select ".flash--notice", /refunded/
    patch cancel_admin_order_path(@waiting)
    assert_equal before + 50, Coins::Balance.total(@buyer)
    assert_equal 1, CoinTransaction.where(user: @buyer, kind: "refund").count
  end

  test "a fulfilled order cannot be cancelled by staff" do
    as_admin
    patch cancel_admin_order_path(@done)
    assert_match(/can't be cancelled/, flash[:alert])
    assert_predicate @done.reload, :fulfilled?
  end

  test "an unknown order id is a 404 for staff" do
    as_admin
    patch fulfill_admin_order_path(0)
    assert_response :not_found
  end

  test "the admin dashboard links to the queue with the requested count" do
    as_admin
    get admin_root_path
    assert_select "a[href='#{admin_orders_path}']", text: "Shop orders"
    assert_select "p", text: /2 requested/
  end
end
