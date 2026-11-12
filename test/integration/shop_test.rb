require "test_helper"
require_relative "../support/shop_helper"

class ShopTest < ActionDispatch::IntegrationTest
  include ShopTestHelper

  setup do
    OmniAuth.config.test_mode = true
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @user = users(:onboarded)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def place_order(prize_key: "tshirt", key: SecureRandom.hex(8))
    post orders_path, params: { prize_key: prize_key, idempotency_key: key }
  end

  # --- access ---

  test "signed-out visitors are sent home from every shop route" do
    get shop_path
    assert_redirected_to root_path
    get shop_item_path("tshirt")
    assert_redirected_to root_path
    get orders_path
    assert_redirected_to root_path
    post orders_path, params: { prize_key: "tshirt", idempotency_key: "x" }
    assert_redirected_to root_path
    post shop_sticker_path
    assert_redirected_to root_path
    assert_equal 0, Order.count
  end

  test "users who have not finished onboarding are sent to onboarding" do
    sign_in_as users(:new_user)
    [ shop_path, orders_path, shop_item_path("tshirt") ].each do |path|
      get path
      assert_redirected_to onboarding_path
    end
  end

  test "shop paths are not swallowed by the referral catch-all" do
    assert_equal({ controller: "shop", action: "index" }, Rails.application.routes.recognize_path("/shop"))
    assert_equal({ controller: "orders", action: "index" }, Rails.application.routes.recognize_path("/shop/orders"))
  end

  test "the header has a Shop link for onboarded users only" do
    sign_in_as @user
    get dashboard_path
    assert_select "nav[aria-label=Account] a[href='/shop']", text: "Shop"
  end

  # --- the locked state ---

  test "an unverified user sees their coins, a friendly note and the verify link, and cannot buy" do
    give_coins(@user, 120)
    sign_in_as @user
    get shop_path
    assert_response :success
    assert_select "#coin-total", text: "120 coins"
    assert_select "#coin-spendable", text: "0 coins"
    assert_select "#shop-verify-note", /unlock when you verify your identity with Hack Club/
    assert_select "#shop-verify-note a[href='https://auth.hackclub.com'][rel~=noopener]", text: "Verify with Hack Club"
    assert_select ".shop-item", Prize.paid.size
    assert_select ".shop-item a", text: "Get this", count: 0
    assert_select ".shop-item button[disabled]", Prize.paid.size
    assert_select ".shop-item button[disabled]", text: /Locked until you verify/, count: Prize.paid.size

    get shop_item_path("tshirt")
    assert_redirected_to shop_path
    assert_match(/verify your identity with Hack Club/, flash[:alert])

    place_order
    assert_redirected_to shop_path
    assert_equal 0, Order.count
    assert_equal 120, Coins::Balance.total(@user)
  end

  test "a pending verification says it is being reviewed instead of linking" do
    @user.update_columns(verification_status: "pending")
    sign_in_as @user
    get shop_path
    assert_select "#shop-verify-note", /being reviewed/
    assert_select "#shop-verify-note a", count: 0
  end

  # --- the grid ---

  test "a verified user sees the grid priced in coins, with Get this only for what they can afford" do
    verified!(@user)
    give_coins(@user, 40)
    sign_in_as @user
    get shop_path
    assert_select "#coin-spendable", text: "40 coins"
    assert_select ".shop-item__name", text: "Battletown T-shirt"
    assert_select ".shop-item__price", text: "50 coins"
    assert_select ".shop-item__price", text: "10 coins"
    assert_select ".shop-tier", 0, "the plain shop tier is not worth a label on every card"
    assert_select ".shop-item a[href='#{shop_item_path('keychain')}']", text: "Get this"
    assert_select ".shop-item a[href='#{shop_item_path('tshirt')}']", count: 0
    assert_select ".shop-item button[disabled]", text: "Need 10 coins more"
  end

  test "plural-safe copy: one coin short reads as one coin" do
    verified!(@user)
    give_coins(@user, 49)
    sign_in_as @user
    get shop_path
    assert_select ".shop-item button[disabled]", text: "Need 1 coin more"
  end

  test "the page has no inline styles or scripts" do
    sign_in_as @user
    get shop_path
    assert_select "[style]", 0
    assert_select "script:not([src]):not([nonce])", 0
  end

  # --- buying ---

  test "confirmation shows the price, the balance afterwards and the delivery note" do
    verified!(@user)
    give_coins(@user, 80)
    sign_in_as @user
    get shop_item_path("tshirt")
    assert_response :success
    assert_select "h1", /Battletown T-shirt/
    assert_select "#confirm-price", text: "50 coins"
    assert_select "#confirm-after", text: "30 coins"
    assert_select ".shop-note", /team will message you on Slack to arrange delivery/
    assert_select "form[action='#{orders_path}'] input[name=idempotency_key][type=hidden]", 1
    assert_select "form[action='#{orders_path}'] input[name=prize_key][value=tshirt]", 1
    assert_select "form[action='#{orders_path}'] button[type=submit]", text: /Place order for 50 coins/
  end

  test "each confirmation page makes its own server-side key" do
    verified!(@user)
    give_coins(@user, 80)
    sign_in_as @user
    get shop_item_path("tshirt")
    one = css_select("input[name=idempotency_key]").first["value"]
    get shop_item_path("tshirt")
    two = css_select("input[name=idempotency_key]").first["value"]
    assert_match(/\A\h{32}\z/, one)
    assert_not_equal one, two
  end

  test "confirming an item you cannot afford, a free item or an unknown one goes nowhere" do
    verified!(@user)
    give_coins(@user, 20)
    sign_in_as @user
    get shop_item_path("tshirt")
    assert_redirected_to shop_path
    get shop_item_path("signup_sticker")
    assert_response :not_found
    get shop_item_path("nope")
    assert_response :not_found
  end

  test "placing an order spends the coins, lists the order and shows the new balance" do
    verified!(@user)
    give_coins(@user, 80)
    sign_in_as @user
    get shop_item_path("tshirt")
    key = css_select("input[name=idempotency_key]").first["value"]
    post orders_path, params: { prize_key: "tshirt", idempotency_key: key }
    assert_redirected_to orders_path
    follow_redirect!
    assert_select ".flash--notice", /Order placed/
    assert_select ".shop-order", 1
    assert_select ".shop-order__name", /Battletown T-shirt/
    assert_select ".shop-status--requested", text: "Requested"
    assert_select ".shop-order .shop-note", /message you on Slack to arrange delivery/
    assert_select ".shop-lead strong", text: "30 coins"
    assert_equal 30, Coins::Balance.total(@user)
  end

  test "submitting the same confirmation twice makes one order" do
    verified!(@user)
    give_coins(@user, 120)
    sign_in_as @user
    2.times { place_order(key: "same-key-123456") }
    assert_redirected_to orders_path
    assert_equal 1, Order.count
    assert_equal 70, Coins::Balance.total(@user)
  end

  test "a forged or odd order submission is refused politely and writes nothing" do
    verified!(@user)
    give_coins(@user, 500)
    sign_in_as @user
    place_order(prize_key: "signup_sticker")
    assert_redirected_to shop_path
    assert_match(/free/, flash[:alert])
    place_order(prize_key: "nope")
    assert_redirected_to shop_path
    post orders_path, params: { prize_key: [ "tshirt" ], idempotency_key: { a: 1 } }
    assert_redirected_to shop_path
    post orders_path, params: { prize_key: "tshirt" }
    assert_redirected_to shop_path
    assert_equal 0, Order.count
    assert_equal 500, Coins::Balance.total(@user)
  end

  test "a price sent by the browser is ignored" do
    verified!(@user)
    give_coins(@user, 100)
    sign_in_as @user
    post orders_path, params: { prize_key: "tshirt", idempotency_key: "price-test-123", coins: 1 }
    assert_equal 50, Order.last.coins
    assert_equal 50, Coins::Balance.total(@user)
  end

  # --- cancelling ---

  test "cancelling a requested order refunds it and the page says so" do
    verified!(@user)
    give_coins(@user, 80)
    sign_in_as @user
    place_order
    order = Order.last
    get orders_path
    assert_select "#order-#{order.id} form[action='#{cancel_order_path(order)}'] button", text: "Cancel order"
    patch cancel_order_path(order)
    assert_redirected_to orders_path
    follow_redirect!
    assert_select ".flash--notice", /coins are back/
    assert_select "#order-#{order.id} .shop-status--cancelled", text: "Cancelled"
    assert_select "#order-#{order.id}", text: /coins refunded/
    assert_select "#order-#{order.id} button", count: 0
    assert_equal 80, Coins::Balance.total(@user)
    patch cancel_order_path(order)
    assert_equal 80, Coins::Balance.total(@user)
  end

  test "a fulfilled order has no cancel button and cannot be cancelled" do
    verified!(@user)
    give_coins(@user, 80)
    sign_in_as @user
    place_order
    order = Order.last
    order.update_columns(status: "fulfilled", fulfilled_at: Time.current)
    get orders_path
    assert_select "#order-#{order.id} .shop-status--fulfilled", text: "Fulfilled"
    assert_select "#order-#{order.id} button", count: 0
    patch cancel_order_path(order)
    assert_redirected_to orders_path
    assert_match(/can't be cancelled/, flash[:alert])
    assert_equal 30, Coins::Balance.total(@user)
  end

  test "another user's order is a 404 to cancel and never appears in the list" do
    other = users(:new_user)
    verified!(other)
    give_coins(other, 100)
    theirs = buy(other, "tshirt")
    sign_in_as @user
    get orders_path
    assert_select ".shop-order", 0
    patch cancel_order_path(theirs)
    assert_response :not_found
    assert_predicate theirs.reload, :requested?
    assert_equal 50, Coins::Balance.total(other)
  end

  # --- the free sticker ---

  test "the free sticker can be claimed once, unverified, and the card goes away" do
    sign_in_as @user
    get shop_path
    assert_select ".shop-sticker h2", text: "Claim your free sticker"
    post shop_sticker_path
    assert_redirected_to orders_path
    follow_redirect!
    assert_select ".shop-order__name", /sticker/i
    assert_select ".shop-order__meta", /Free/
    assert_select ".shop-order button", count: 0, text: "Cancel order"
    get shop_path
    assert_select ".shop-sticker", 0
    post shop_sticker_path
    assert_redirected_to shop_path
    assert_match(/already claimed/, flash[:alert])
    assert_equal 1, Order.where(user: @user, kind: "signup_sticker").count
  end

  test "an empty orders page invites you to the shop" do
    sign_in_as @user
    get orders_path
    assert_select "h2", text: "No orders yet"
  end

  test "no address field exists anywhere in the shop flow" do
    verified!(@user)
    give_coins(@user, 80)
    sign_in_as @user
    [ shop_path, shop_item_path("tshirt"), orders_path ].each do |path|
      get path
      assert_select "input[name*=address], textarea, input[type=tel], input[name*=phone]", 0
    end
  end

  # --- development-only coins ---

  test "the dev coins endpoint is a 404 outside development and the button is not shown" do
    sign_in_as @user
    get shop_path
    assert_select ".dev-only", 0
    post dev_coins_path
    assert_response :not_found
    assert_equal 0, Coins::Balance.total(@user)
  end
end
