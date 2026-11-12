require "test_helper"
require_relative "../support/orders_helper"
require_relative "../support/admin_sign_in"

# The buyer's own order page (/shop/orders/:id) and the orders list: who sees what, in plain words.
class OrderPageTest < ActionDispatch::IntegrationTest
  include OrdersTestHelper
  include AdminSignIn

  setup do
    setup_orders_world(coins: 1000)
    @buyer.update_columns(onboarded_at: Time.utc(2026, 11, 1), onboarding_step: 4)
    @other.update_columns(onboarded_at: Time.utc(2026, 11, 1), onboarding_step: 4)
  end

  teardown { teardown_orders_world }

  test "signed-out visitors are sent away and other people's orders are a 404" do
    order = order_for
    get order_path(order)
    assert_response :redirect
    assert_not_includes response.body, order.display_name

    sign_in_as @other
    get order_path(order)
    assert_response :not_found
    patch cancel_order_path(order)
    assert_response :not_found
    assert_predicate order.reload, :requested?
    get order_path(0)
    assert_response :not_found
  end

  test "the owner sees the item, price, status in words, a plain timeline and the delivery note" do
    order = order_for
    sign_in_as @buyer
    get order_path(order)
    assert_response :success
    assert_select "title", /Order: Battletown T-shirt/
    assert_select "h1", "Battletown T-shirt"
    assert_select ".shop-status.shop-status--requested", text: "Requested"
    assert_select ".shop-sums", text: /50 coins/
    assert_select ".shop-timeline li", 1
    assert_select ".shop-timeline li", text: /Ordered/
    assert_select ".shop-note", text: /The team will message you on Slack to arrange delivery/
    assert_select "form[action='#{cancel_order_path(order, from: 'order')}'] button", text: "Cancel order"
    assert_select "a[href='#{orders_path}']", text: "Back to your orders"
  end

  test "an order with an address says it will be posted there, not that the team will arrange delivery on Slack" do
    order = order_for(address: true)
    sign_in_as @buyer
    get order_path(order)
    assert_select ".shop-note", text: /The team will post it to the address you chose/
    assert_select ".shop-note", text: /arrange delivery/, count: 0
    get orders_path
    assert_select ".shop-note", text: /The team will post it to the address you chose/
  end

  test "the page that shows the buyer's address keeps itself out of Turbo's back/forward snapshots" do
    order = order_for(address: true)
    sign_in_as @buyer
    get order_path(order)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "meta[name=turbo-cache-control][content=no-cache]", 1
  end

  test "each status has a word, a plain explanation and a mark class, and only requested can be cancelled" do
    sign_in_as @buyer
    expected = {
      "requested" => [ "Requested", /has your order/, true ],
      "shipped" => [ "Shipped", /on its way/, false ],
      "fulfilled" => [ "Fulfilled", /handed over/, false ],
      "cancelled" => [ "Cancelled", /was cancelled\. Your 50 coins are back/, false ],
      "refunded" => [ "Refunded", /was refunded\. Your 50 coins are back/, false ]
    }
    expected.each do |status, (word, explanation, cancellable)|
      order = order_in(status)
      get order_path(order)
      assert_select ".shop-status.shop-status--#{status}", text: word
      assert_select ".page-header .lead", text: explanation
      assert_select "button", text: "Cancel order", count: cancellable ? 1 : 0
    end
  end

  test "a hold shows as Requested with exactly the same text, and leaks no staff note, reason or hold" do
    order = order_for
    plain = begin
      sign_in_as @buyer
      get order_path(order)
      css_select(".page-header .lead").first.text.squish
    end
    Orders::Hold.call(order: order, by: @staff, as: :staff, reason_code: "fraud_abuse", note: "Looks like a resale account")
    Orders::AddNote.call(order: order, by: @staff, note: "Secret staff chatter")
    get order_path(order)
    assert_equal plain, css_select(".page-header .lead").first.text.squish
    assert_select ".shop-status", text: "Requested"
    assert_select ".shop-timeline li", 1, "no timeline line for a hold or a note"
    [ /on hold/i, /\bhold\b/i, /fraud/i, /resale/i, /Secret/, /reason/i, /staff/i ].each do |leak|
      assert_no_match leak, css_select("main").to_s, "the buyer page must not match #{leak}"
    end
    get orders_path
    assert_select "#order-#{order.id} .shop-status", text: "Requested"
    assert_no_match(/on hold|fraud|resale|Secret/i, response.body)
    assert_select "#order-#{order.id} button", 0, "a held order has no cancel button (the buyer asks the team)"
  end

  test "the timeline lists only plain status changes with dates, never a note, a reason or a tracking edit" do
    order = order_for(address: true)
    Orders::Ship.call(order: order, by: @staff, as: :staff, tracking: { carrier: "ups", number: "1Z999AA10123456784" }, note: "Packed in blue box")
    Orders::UpdateTracking.call(order: order, by: @staff, tracking: { carrier: "ups", number: "1Z999AA10123456785" })
    Orders::Fulfil.call(order: order, by: @staff, as: :staff, note: "Left at the door")
    Orders::Refund.call(order: order, by: @staff, as: :staff, reason_code: "address_problem", note: "Lost")
    sign_in_as @buyer
    get order_path(order)
    lines = css_select(".shop-timeline li").map { |li| li.text.squish }
    assert_equal 4, lines.size
    assert_match(/Ordered \d/, lines[0])
    assert_match(/Shipped \d/, lines[1])
    assert_match(/Fulfilled \d/, lines[2])
    assert_match(/Refunded \d/, lines[3])
    main = css_select("main").to_s.downcase
    [ "Packed", "Left at", "Lost", "address", "Delivery problem", "1z999aa10123456785" ].each { |leak| assert_not_includes main, leak.downcase, leak }
  end

  test "tracking shows with a link on the owner's shipped order, never on the list, and not on a cancelled one" do
    order = order_in("shipped")
    sign_in_as @buyer
    get order_path(order)
    assert_select ".shop-tracking", text: /UPS 1Z999AA10123456784/
    assert_select "a.shop-tracking__link[href='https://www.ups.com/track?tracknum=1Z999AA10123456784'][rel='noopener noreferrer nofollow'][target='_blank']"
    get orders_path
    assert_not_includes response.body, "1Z999AA10123456784"
    get order_path(order_for)
    assert_select ".shop-tracking", 0
  end

  test "a tracking number is only ever on the owner's page: another person gets a 404 with nothing in it" do
    order = order_in("shipped")
    sign_in_as @other
    get order_path(order)
    assert_response :not_found
    assert_not_includes response.body, "1Z999AA10123456784"
  end

  test "the list links to each order and shows a word for all six statuses" do
    orders = Order::STATUSES.to_h { |status| [ status, order_in(status) ] }
    sign_in_as @buyer
    get orders_path
    orders.each do |status, order|
      word = OrderStatusHelper::STAFF_STATUS_TEXT.fetch(order.buyer_status)
      assert_select "#order-#{order.id} .shop-status", text: word
      assert_select "#order-#{order.id} a[href='#{order_path(order)}']"
      assert_equal 1, css_select("#order-#{order.id} .shop-status").size, status
    end
    assert_select "#order-#{orders['on_hold'].id} .shop-status", text: "Requested"
  end

  test "cancelling from the order page goes back to the order page and refunds once" do
    order = order_for
    sign_in_as @buyer
    patch cancel_order_path(order, from: "order")
    assert_redirected_to order_path(order)
    follow_redirect!
    assert_select ".flash--notice", /Your coins are back/
    assert_select ".shop-status", text: "Cancelled"
    patch cancel_order_path(order, from: "order")
    assert_equal 1, refunds_for.count
    assert_equal 1000, Coins::Balance.total(@buyer)
    assert_equal "buyer", order.events.last.actor_kind
  end

  test "cancelling a shipped order is refused with a friendly message, back on the page" do
    order = order_in("shipped")
    sign_in_as @buyer
    patch cancel_order_path(order, from: "order")
    assert_redirected_to order_path(order)
    follow_redirect!
    assert_select ".flash--alert", /can't be cancelled/
    assert_predicate order.reload, :shipped?
  end

  test "placing an order lands on its page, and the cap on waiting orders gives a friendly error" do
    sign_in_as @buyer
    cap = Orders::Config.current.max_open_requested
    cap.times do |i|
      key = SecureRandom.hex(16)
      post orders_path, params: { prize_key: "custom_sticker", idempotency_key: key, address_id: offer_addresses!(@buyer, key).first }
      assert_redirected_to order_path(Order.find_by!(user: @buyer, idempotency_key: key))
    end
    extra = SecureRandom.hex(16)
    post orders_path, params: { prize_key: "custom_sticker", idempotency_key: extra, address_id: offer_addresses!(@buyer, extra).first }
    assert_redirected_to shop_path
    follow_redirect!
    assert_select ".flash--alert", /#{cap} orders waiting/
    assert_equal cap, Order.where(user: @buyer).count
  end

  test "the signup sticker order has no cancel button for its owner" do
    sticker = Shop::ClaimSticker.call(user: @other)
    sign_in_as @other
    get order_path(sticker)
    assert_select ".shop-status", text: "Requested"
    assert_select "button", text: "Cancel order", count: 0
    assert_select ".shop-sums", text: /Free/
  end

  test "there is no address, phone or free-text field on the order page and no inline script or style" do
    order = order_for
    sign_in_as @buyer
    get order_path(order)
    assert_select "input[name*=address], textarea, input[type=tel], input[name*=phone]", 0
    assert_select "main script", 0
    assert_select "main [style]", 0
  end
end
