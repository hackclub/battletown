require "test_helper"
require_relative "../support/orders_helper"

# The address step on the confirm page, placing the order with the chosen address, the free sticker, and the buyer's own order page
# (ship-to, change address). The Hack Club Auth round trip itself is tested in address_lookup_*; here the offer is stored directly.
class CheckoutAddressPagesTest < ActionDispatch::IntegrationTest
  include OrdersTestHelper

  setup do
    setup_orders_world(coins: 500)
    @buyer.update_columns(onboarded_at: Time.utc(2026, 11, 1), onboarding_step: 4)
    @other.update_columns(onboarded_at: Time.utc(2026, 11, 1), onboarding_step: 4)
    @draft = SecureRandom.hex(16)
    OmniAuth.config.test_mode = true
    sign_in_as @buyer
  end

  teardown do
    teardown_orders_world
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def offer(draft = @draft, addresses = [ hca_address("addr_home", primary: true), hca_address("addr_school", country: "GB") ])
    offer_addresses!(@buyer, draft, addresses)
  end

  # --- the confirm page ---

  test "before any lookup the page offers the button, shows the notice from config, and the order button is off" do
    get shop_item_path("tshirt", draft: @draft)
    assert_response :success
    assert_select "#address-heading", "Where should we send it?"
    assert_select ".address-step__notice", text: "We only use your address to post your prize. We keep it for 30 days after it ships, then delete it. You can see and change it until it ships."
    assert_select "form[action='/auth/hack_club_address'][method=post][data-turbo=false]" do
      assert_select "input[name=purpose][value=checkout]"
      assert_select "input[name=item][value=tshirt]"
      assert_select "input[name=draft][value='#{@draft}']"
      assert_select "button", text: "Get my addresses from Hack Club Auth"
    end
    assert_select "select#address-choice", 0
    assert_select "button[disabled]", text: /Place order for 50 coins/
    assert_select "input[name=idempotency_key][value='#{@draft}']", 1, "the page and the lookup share one draft key"
  end

  test "the notice follows the configured retention period" do
    with_orders_config(address_retention_days: 14) do
      get shop_item_path("tshirt", draft: @draft)
      assert_select ".address-step__notice", /for 14 days after it ships/
    end
  end

  test "a draft key that is not well formed is replaced, so a link cannot choose the key" do
    get shop_item_path("tshirt", draft: "../../etc/passwd")
    key = css_select("input[name=idempotency_key]").first["value"]
    assert_match(/\A[0-9a-f]{32}\z/, key)
  end

  test "with a loaded list the page shows a labelled dropdown, primary marked, a preview per address and an off button" do
    offer
    get shop_item_path("tshirt", draft: @draft)
    assert_select "label[for=address-choice]", "Ship to"
    assert_select "select#address-choice[name=address_id][form=order-form][required]" do
      assert_select "option[value='']", text: "Choose an address"
      assert_select "option[value=addr_home]", text: "Home Example Street, Exampleville, US (primary)"
      assert_select "option[value=addr_school]", text: "School Example Street, Exampleville, GB"
      assert_select "option[selected]", 0
    end
    assert_select ".address-preview[hidden]", 2
    assert_select "[data-address-id=addr_school] address", /Pat Example/
    assert_select "[data-address-id=addr_school] address", /Exampleville, EX, 00000/
    assert_select "[data-address-id=addr_school] address", /Phone ends in 0123/
    assert_select "form#order-form button[disabled]", text: /Place order/
    assert_select "[data-controller=ship-to-picker]", 1
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "meta[name=turbo-cache-control][content=no-cache]", 1
  end

  test "an expired list says so and offers the button again" do
    offer
    travel 20.minutes do
      get shop_item_path("tshirt", draft: @draft)
      assert_select ".address-step", /That took a while, so we forgot your addresses to keep them safe/
      assert_select "button", text: "Get my addresses from Hack Club Auth"
      assert_select "select#address-choice", 0
    end
  end

  test "someone else's list is never shown" do
    offer_addresses!(@other, @draft, [ hca_address("addr_theirs") ])
    get shop_item_path("tshirt", draft: @draft)
    assert_select "option[value=addr_theirs]", 0
    assert_no_match(/Theirs Example/, response.body)
  end

  test "an item that is not posted has no address step and orders as before" do
    ShopItem.find_by!(key: "keychain").update!(requires_shipping: false)
    get shop_item_path("keychain")
    assert_select ".address-step", 0
    assert_select "form[action='/auth/hack_club_address']", 0
    assert_select "button[disabled]", 0
    assert_select ".shop-note", /message you on Slack to arrange delivery/
    key = css_select("input[name=idempotency_key]").first["value"]
    post orders_path, params: { prize_key: "keychain", idempotency_key: key }
    assert_redirected_to order_path(Order.last)
    assert_nil Order.last.address
    assert_not Order.last.address_needed?
    assert_equal 0, OrderAddress.count
    follow_redirect!
    assert_select ".shop-ship-to", 0
    assert_select ".flash--notice", /message you on Slack/
  end

  # --- placing the order ---

  test "choosing the non-primary address places the order with exactly that address, and the order page shows it" do
    ids = offer
    assert_includes ids, "addr_school"
    post orders_path, params: { prize_key: "tshirt", idempotency_key: @draft, address_id: "addr_school" }
    order = Order.find_by!(user: @buyer, idempotency_key: @draft)
    assert_redirected_to order_path(order)
    assert_equal [ "School Example Street", "GB", "addr_school" ], order.address.then { |a| [ a.line_1, a.country, a.hca_address_id ] }
    follow_redirect!
    assert_select ".flash--notice", /post it to the address you picked/
    assert_select ".shop-ship-to address", /School Example Street/
    assert_select ".shop-ship-to address", /GB/
    assert_select ".shop-ship-to address", /Phone ends in 0123/
    assert_no_match(/\+15555550123/, response.body, "the full number is not shown")
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".shop-ship-to button", text: "Change address"
    assert_equal 450, Coins::Balance.total(@buyer)
  end

  test "address text posted by the browser is never read: only the id counts" do
    offer
    post orders_path, params: { prize_key: "tshirt", idempotency_key: @draft, address_id: "addr_home", line_1: "Hacked 9 Street", city: "Forgeville",
                                country: "ZZ", address: { line_1: "Hacked 9 Street" }, recipient_name: "Mallory" }
    address = Order.last.address
    assert_equal [ "Home Example Street", "Exampleville", "US", "Pat Example" ], [ address.line_1, address.city, address.country, address.recipient_name ]
  end

  test "no address, a tampered id, or an expired list places nothing and goes back to the confirm page with a friendly message" do
    offer
    [ [ nil, /Choose where to send it first/ ], [ "addr_other", /isn't one we loaded for you/ ], [ "", /Choose where to send it first/ ] ].each do |id, message|
      post orders_path, params: { prize_key: "tshirt", idempotency_key: @draft, address_id: id }.compact
      assert_redirected_to shop_item_path("tshirt", draft: @draft)
      follow_redirect!
      assert_select ".flash--alert", message
      assert_equal 0, Order.count
    end
    travel 20.minutes do
      post orders_path, params: { prize_key: "tshirt", idempotency_key: @draft, address_id: "addr_home" }
      follow_redirect!
      assert_select ".flash--alert", /That took a while/
      assert_select "button", text: "Get my addresses from Hack Club Auth"
    end
    assert_equal 0, Order.count
    assert_equal 500, Coins::Balance.total(@buyer)
  end

  test "pressing Place order twice, refreshing the POST, or going back and forward all land on the one order" do
    offer
    2.times { post orders_path, params: { prize_key: "tshirt", idempotency_key: @draft, address_id: "addr_home" } }
    order = Order.find_by!(user: @buyer, idempotency_key: @draft)
    assert_redirected_to order_path(order)
    assert_equal 1, Order.count
    assert_equal 1, OrderAddress.count
    get shop_item_path("tshirt", draft: @draft) # the back button
    assert_redirected_to order_path(order)
  end

  test "the order cap still applies" do
    with_orders_config(max_open_requested: 1) do
      post_order_as @buyer, key: SecureRandom.hex(16)
      second = SecureRandom.hex(16)
      post_order_as @buyer, key: second
      assert_redirected_to shop_path
      assert_equal 1, Order.count
      assert_equal 1, OrderAddress.count
    end
  end

  # --- the free sticker ---

  test "the shop's sticker card leads to a page with the address step, and claiming needs an offered address" do
    get shop_path
    assert_select ".shop-sticker a[href='/shop/sticker']", text: "Claim your free sticker"
    assert_select ".shop-sticker", /choose where to send it/
    get new_shop_sticker_path
    assert_select "#address-heading", "Where should we send it?"
    assert_select "form[action='/auth/hack_club_address'] input[name=purpose][value=sticker]"
    assert_select "#sticker-form button[disabled]", text: "Claim your free sticker"

    post shop_sticker_path
    assert_redirected_to new_shop_sticker_path
    assert_equal 0, Order.count

    offer_addresses!(@buyer, "sticker", [ hca_address("addr_stick") ])
    get new_shop_sticker_path
    assert_select "select#address-choice[form=sticker-form] option[value=addr_stick]"
    post shop_sticker_path, params: { address_id: "addr_stick" }
    assert_redirected_to orders_path
    assert_equal "addr_stick", Order.find_by!(user: @buyer, kind: "signup_sticker").address.hca_address_id
    get new_shop_sticker_path
    assert_redirected_to orders_path # claimed already
  end

  test "a sticker that is not posted is claimed with no address step" do
    ShopItem.find_by!(key: "signup_sticker").update!(requires_shipping: false)
    get new_shop_sticker_path
    assert_select ".address-step", 0
    post shop_sticker_path
    assert_redirected_to orders_path
    assert_nil Order.find_by!(user: @buyer, kind: "signup_sticker").address
  end

  # --- the buyer's order page ---

  def placed_order(prize: "tshirt") = order_for(@buyer, prize: prize, address: true)

  test "a waiting order shows its address, a Change address button and the notice; an order with none offers to add one" do
    order = placed_order
    get order_path(order)
    assert_select ".shop-ship-to address", /1 Example Street/
    assert_select ".shop-ship-to form[action='/auth/hack_club_address'][data-turbo=false]" do
      assert_select "input[name=purpose][value=change]"
      assert_select "input[name=order_id][value='#{order.id}']"
    end
    assert_select ".shop-ship-to", /You can change this until the team sends the order/

    bare = order_for(@buyer, prize: "keychain")
    get order_path(bare)
    assert_select ".shop-ship-to", /No address yet/
    assert_select ".shop-ship-to button", text: "Add an address"
  end

  test "the change-address page lists the loaded addresses and saving replaces the stored one without changing the status" do
    order = placed_order
    offer_addresses!(@buyer, "order-#{order.id}", [ hca_address("addr_new", line_1: "9 Newer Street", country: "AU") ])
    get address_order_path(order)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "select#address-choice[form=address-form] option[value=addr_new]"
    assert_select "#address-form button[disabled]", text: "Use this address"

    patch update_address_order_path(order), params: { address_id: "addr_new" }
    assert_redirected_to order_path(order)
    follow_redirect!
    assert_select ".flash--notice", "Address updated."
    assert_equal [ "9 Newer Street", "AU", "addr_new" ], order.reload.address.then { |a| [ a.line_1, a.country, a.hca_address_id ] }
    assert_equal 1, OrderAddress.where(order_id: order.id).count
    assert_predicate order, :requested?

    event = order.events.find_by!(action: "address_changed")
    assert_equal [ "buyer", nil, "requested", "requested", nil, nil ], [ event.actor_kind, event.actor_id, event.from_status, event.to_status, event.note, event.reason_code ]
    assert_empty AddressOffer.find_by!(user: @buyer, draft_key: "order-#{order.id}").addresses
  end

  test "an order on hold can change its address too; the buyer is not told it is on hold" do
    order = placed_order
    staff_do("Hold", order)
    offer_addresses!(@buyer, "order-#{order.id}", [ hca_address("addr_new") ])
    patch update_address_order_path(order), params: { address_id: "addr_new" }
    assert_equal "addr_new", order.reload.address.hca_address_id
    assert_predicate order, :on_hold?
  end

  test "once an order is shipped, fulfilled, cancelled or refunded its address cannot be changed" do
    %w[shipped fulfilled refunded cancelled].each do |status|
      order = order_in(status)
      offer_addresses!(@buyer, "order-#{order.id}", [ hca_address("addr_new") ])
      address_before = order.address&.hca_address_id
      get address_order_path(order)
      assert_redirected_to order_path(order)
      patch update_address_order_path(order), params: { address_id: "addr_new" }
      assert_redirected_to order_path(order), status
      assert_equal address_before.to_s, OrderAddress.find_by(order_id: order.id)&.hca_address_id.to_s, status
      assert_equal 0, order.events.where(action: "address_changed").count, status
      get order_path(order)
      assert_select ".shop-ship-to button", 0
    end
  end

  test "a shipped order still shows its address, read-only, with the deletion promise" do
    order = order_in("shipped")
    give_address!(order) unless order.address
    get order_path(order)
    assert_select ".shop-ship-to address", /1 Example Street/
    assert_select ".shop-ship-to", /can't be changed/
    assert_select ".shop-ship-to", /We delete it 30 days after it ships/
  end

  test "changing the address with a stale list, a wrong id or none says so and changes nothing" do
    order = placed_order
    patch update_address_order_path(order), params: { address_id: "addr_x" }
    assert_redirected_to address_order_path(order)
    follow_redirect!
    assert_select ".flash--alert", /That took a while|Choose where to send/
    offer_addresses!(@buyer, "order-#{order.id}", [ hca_address("addr_new") ])
    patch update_address_order_path(order), params: { address_id: "addr_other" }
    assert_equal "addr_test", order.reload.address.hca_address_id
  end

  test "another person's order address page, change and lookup are a 404 or refused, and change nothing" do
    order = placed_order
    sign_in_as @other
    offer_addresses!(@other, "order-#{order.id}", [ hca_address("addr_new") ])
    get address_order_path(order)
    assert_response :not_found
    patch update_address_order_path(order), params: { address_id: "addr_new" }
    assert_response :not_found
    get order_path(order)
    assert_response :not_found
    assert_equal "addr_test", order.reload.address.hca_address_id
  end

  test "signed-out visitors are sent away from every address page" do
    delete logout_path
    order = placed_order
    [ [ :get, new_shop_sticker_path ], [ :get, address_order_path(order) ], [ :patch, update_address_order_path(order) ], [ :get, "/auth/hack_club_address/callback" ] ].each do |verb, path|
      process(verb, path)
      assert_response :redirect, "#{verb} #{path}"
      assert_redirected_to root_path
    end
  end

  # --- what the messages and the list never carry ---

  test "shipping sends the buyer a message and email that never carry the address" do
    Flipper.enable(:email)
    @buyer.update_columns(email: "teen-orders@example.test")
    order = placed_order
    staff_do("Ship", order, tracking: { carrier: "ups", number: "1Z999AA10123456784" })
    texts = Notification.where(user_id: @buyer.id).map { |row| row.attributes.values.join(" ") }.join("\n")
    assert_not_includes texts, "Example Street"
    assert_not_includes texts, "+15555550123"
    assert_not_includes texts, "Exampleville"
    ActionMailer::Base.deliveries.each { |mail| assert_not_includes mail.to_s, "Example Street" }
  end

  test "the buyer's orders list never shows the address" do
    placed_order
    get orders_path
    assert_no_match(/Example Street|Exampleville|\+1555/, response.body)
  end
end
