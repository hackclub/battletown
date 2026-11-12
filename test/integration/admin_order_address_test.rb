require "test_helper"
require_relative "../support/orders_helper"
require_relative "../support/admin_sign_in"
require_relative "../support/hackatime_helper"
require "csv"

# Shipping addresses as staff meet them: country and city by default, an audited one-response reveal, never in lists, the CSV, logs or
# messages, no editing, and "Needs an address" before an order can be shipped (with an audited override for older orders).
class AdminOrderAddressTest < ActionDispatch::IntegrationTest
  include OrdersTestHelper
  include AdminSignIn
  include HackatimeHelper # capture_logs

  STREET = "1 Example Street".freeze
  PHONE = "+15555550123".freeze

  setup do
    setup_orders_world(coins: 1000)
    @buyer.update_columns(created_at: Time.utc(2026, 11, 1, 12))
    @order = order_for(@buyer, prize: "tshirt", address: true)
    ENV["ADMIN_HCA_UIDS"] = @staff.hca_uid
    sign_in_as @staff
  end

  teardown { teardown_orders_world }

  def reveal(order = @order) = post(reveal_address_admin_order_path(order))

  # --- the default view ---

  test "the order page shows the country and city only, with a Reveal button, and no street, name or phone" do
    get admin_order_path(@order)
    assert_select "#order-address-panel dd", text: "US"
    assert_select "#order-address-panel dd", text: "Exampleville"
    assert_no_match(/Example Street|Flat 2|00000|#{Regexp.escape(PHONE)}|Pat Example/, css_select("#order-address-panel").text)
    assert_no_match(/Example Street|#{Regexp.escape(PHONE)}/, response.body)
    assert_select "#order-address-panel form[action='#{reveal_address_admin_order_path(@order)}'][method=post][data-turbo=false][data-controller=confirm]" do
      assert_select "button", text: "Reveal full address"
    end
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "an order with no address says so: needed, not posted, or gone" do
    needed = order_for(@buyer, prize: "keychain")
    get admin_order_path(needed)
    assert_select "#address-needed-chip", "Address needed"
    ShopItem.find_by!(key: "poster").update!(requires_shipping: false)
    plain = order_for(@buyer, prize: "poster")
    get admin_order_path(plain)
    assert_select "#order-address-panel", /not posted, so there is no address/
    gone = order_in("shipped")
    OrderAddress.where(order_id: gone.id).delete_all
    get admin_order_path(gone)
    assert_select "#order-address-panel", /No address on file/
  end

  # --- the reveal ---

  test "revealing shows the full address on that response only, after writing the audit row and the history entry" do
    assert_difference [ -> { AdminAuditEvent.where(action: "order_address_revealed").count }, -> { @order.events.where(action: "address_revealed").count } ], 1 do
      reveal
    end
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "meta[name=turbo-cache-control][content=no-cache]", 1, "Turbo must not keep a snapshot of the revealed address"
    assert_select "#revealed-address", /Pat Example/
    assert_select "#revealed-address", /#{STREET}/
    assert_select "#revealed-address", /Flat 2/
    assert_select "#revealed-address", /Exampleville, EX, 00000/
    assert_select "#revealed-address", /#{Regexp.escape(PHONE)}/

    audit = AdminAuditEvent.where(action: "order_address_revealed").last
    assert_equal [ @staff.id, "Order", @order.id, { "order_id" => @order.id } ], [ audit.actor_id, audit.subject_type, audit.subject_id, audit.metadata ]
    event = @order.events.find_by!(action: "address_revealed")
    assert_equal [ "staff", @staff.id, nil, nil, "requested", "requested" ], [ event.actor_kind, event.actor_id, event.note, event.reason_code, event.from_status, event.to_status ]

    get admin_order_path(@order)
    assert_no_match(/#{STREET}/, response.body, "the address is not on any later page")
    assert_select "#revealed-address", 0
  end

  test "every reveal is recorded, one row each" do
    3.times { reveal }
    assert_equal 3, AdminAuditEvent.where(action: "order_address_revealed").count
    assert_equal 3, @order.events.where(action: "address_revealed").count
    get admin_order_path(@order)
    assert_select ".admin-history li strong", text: "Address revealed", count: 3
  end

  test "the audit row is written before the page is built: a failure while building it still leaves the record" do
    original = Admin::OrdersController.instance_method(:load_show)
    Admin::OrdersController.define_method(:load_show) { raise "page failed" }
    begin
      Rails.application.env_config["action_dispatch.show_exceptions"] = :none
      assert_raises(RuntimeError) { reveal }
    ensure
      Rails.application.env_config.delete("action_dispatch.show_exceptions")
      Admin::OrdersController.define_method(:load_show, original)
    end
    assert_equal 1, AdminAuditEvent.where(action: "order_address_revealed").count
  end

  test "revealing an order with no address writes nothing and says so" do
    bare = order_for(@buyer, prize: "keychain")
    assert_no_difference -> { AdminAuditEvent.count } do
      reveal(bare)
    end
    assert_redirected_to admin_order_path(bare)
    follow_redirect!
    assert_select ".flash--alert", /no address on file/
  end

  test "revealing is limited per staff member per hour" do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    with_orders_config(address_reveals_per_hour: 2) do
      2.times { reveal }
      assert_response :success
      reveal
      assert_response :too_many_requests
    end
    assert_equal 2, AdminAuditEvent.where(action: "order_address_revealed").count
  ensure
    Rack::Attack.enabled = false
  end

  test "non-admins and signed-out visitors get a 404 and no audit row" do
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    reveal
    assert_response :not_found
    delete logout_path
    reveal
    assert_response :not_found
    assert_equal 0, AdminAuditEvent.where(action: "order_address_revealed").count
  end

  test "revealing needs the CSRF token" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    reveal
    assert_response :unprocessable_content
    assert_equal 0, AdminAuditEvent.where(action: "order_address_revealed").count
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "staff cannot edit an address: there is no such route" do
    %i[patch put post delete].each do |verb|
      process(verb, "/admin/orders/#{@order.id}/address", params: { line_1: "Elsewhere" })
      assert_response :not_found
    end
    assert_equal STREET, @order.reload.address.line_1
  end

  # --- where it never appears ---

  test "the address is not in the queue, the CSV (even with contact columns), the audit page or the log; the country is the only part exported" do
    reveal
    logs = capture_logs do
      get admin_orders_path
      assert_no_match(/#{STREET}|Exampleville|#{Regexp.escape(PHONE)}|Pat Example/, response.body)
      assert_select "#order-#{@order.id} small", /ships to US/

      post export_admin_orders_path, params: { include_contact: "1" }
      csv = response.body
      assert_no_match(/#{STREET}|Exampleville|#{Regexp.escape(PHONE)}|Pat Example|Flat 2/, csv)
      table = CSV.parse(csv, headers: true)
      assert_equal "US", table.find { |row| row["order_id"] == @order.id.to_s }["ship_country"]
      post export_admin_orders_path
      assert_not_includes CSV.parse(response.body, headers: true).headers, "ship_country", "without the contact opt-in there is no country column"

      get admin_audit_path
      assert_no_match(/#{STREET}|Exampleville|#{Regexp.escape(PHONE)}/, response.body)
      assert_match(/order address revealed/i, response.body)
    end
    assert_no_match(/#{STREET}|Exampleville|#{Regexp.escape(PHONE)}|Pat Example/, logs)
  end

  test "the reveal request leaves no address in the log" do
    logs = capture_logs { reveal }
    assert_no_match(/#{STREET}|Exampleville|#{Regexp.escape(PHONE)}|Pat Example/, logs)
  end

  test "audit and history rows hold no address text, even after shipping and purging" do
    reveal
    staff_do("Ship", @order)
    Orders::PurgeAddresses.call(now: 40.days.from_now)
    rows = AdminAuditEvent.all.map { |row| row.attributes.values.join(" ") } + OrderEvent.all.map { |row| row.attributes.values.join(" ") }
    assert_no_match(/#{STREET}|Exampleville|#{Regexp.escape(PHONE)}|Pat Example/, rows.join("\n"))
  end

  # --- shipping ---

  test "a physical order with no address cannot be shipped: a friendly error, nothing changes, and the chip shows in the queue" do
    bare = order_for(@buyer, prize: "keychain")
    get admin_orders_path
    assert_select "#order-#{bare.id} .badge", text: "Address needed"
    assert_select "#order-#{@order.id} .badge", text: "Address needed", count: 0

    get admin_order_path(bare)
    assert_select "#ship-needs-address", /Needs an address/
    assert_select "#ship_override_reason"

    patch ship_admin_order_path(bare)
    assert_redirected_to admin_order_path(bare)
    follow_redirect!
    assert_select ".flash--alert", /Needs an address/
    assert_predicate bare.reload, :requested?
    assert_equal 0, AdminAuditEvent.where(action: "order_shipped", subject_id: bare.id).count
  end

  test "an order with an address ships as before and shows no override" do
    get admin_order_path(@order)
    assert_select "#ship-needs-address", 0
    assert_select "#ship_override_reason", 0
    patch ship_admin_order_path(@order)
    assert_predicate @order.reload, :shipped?
  end

  test "the override needs a reason and is audited: who, which order, why, and the history says so" do
    bare = order_for(@buyer, prize: "keychain")
    patch ship_admin_order_path(bare), params: { address_override: "1", address_override_reason: "" }
    assert_predicate bare.reload, :requested?, "ticking the box without a reason does nothing"

    patch ship_admin_order_path(bare), params: { address_override: "1", address_override_reason: "Gave the address on Slack, order from before addresses", note: "Packed" }
    assert_predicate bare.reload, :shipped?
    audit = AdminAuditEvent.find_by!(action: "order_shipped", subject_id: bare.id)
    assert_equal true, audit.metadata["override"]
    assert_equal "Gave the address on Slack, order from before addresses", audit.metadata["override_reason"]
    assert_equal @staff.id, audit.actor_id
    event = bare.events.find_by!(action: "shipped")
    assert_equal "Shipped without an address: Gave the address on Slack, order from before addresses. Packed", event.note
  end

  test "an override reason that is too long or has control characters is refused" do
    bare = order_for(@buyer, prize: "keychain")
    patch ship_admin_order_path(bare), params: { address_override: "1", address_override_reason: "x" * 201 }
    assert_predicate bare.reload, :requested?
    patch ship_admin_order_path(bare), params: { address_override: "1", address_override_reason: "bad\u0007reason" }
    assert_predicate bare.reload, :requested?
  end

  test "an override is not recorded for an order that has an address" do
    patch ship_admin_order_path(@order), params: { address_override: "1", address_override_reason: "just in case" }
    audit = AdminAuditEvent.find_by!(action: "order_shipped", subject_id: @order.id)
    assert_nil audit.metadata["override"]
    assert_no_match(/Shipped without an address/, @order.events.find_by!(action: "shipped").note.to_s)
  end

  test "an item that is not posted ships without an address and without an override" do
    ShopItem.find_by!(key: "poster").update!(requires_shipping: false)
    plain = order_for(@buyer, prize: "poster")
    get admin_orders_path
    assert_select "#order-#{plain.id} .badge", text: "Address needed", count: 0
    patch ship_admin_order_path(plain)
    assert_predicate plain.reload, :shipped?
  end

  test "marking fulfilled does not need an address" do
    bare = order_for(@buyer, prize: "keychain")
    patch fulfil_admin_order_path(bare)
    assert_predicate bare.reload, :fulfilled?
  end

  test "shipping starts the clock and the order page says when the address will be deleted" do
    patch ship_admin_order_path(@order)
    get admin_order_path(@order)
    assert_select "#order-address-panel dt", text: "Deleted on"
    assert_select "#order-address-panel dd", text: (Time.current + 30.days).utc.strftime("%-d %b %Y")
  end

  # --- the catalogue switch ---

  test "staff can clear 'posted to the buyer' on an item, and the change is audited" do
    patch admin_shop_item_path("poster"), params: { shop_item: { name: "Poster", description: "Boss art poster.", emoji: "x", coins: 40, tier: "shop", position: 5, lock_version: 0, requires_shipping: "0" } }
    assert_not ShopItem.find_by!(key: "poster").requires_shipping
    assert_not Prize.find("poster").requires_shipping?
    audit = AdminAuditEvent.where(action: "shop_item_updated").last
    assert_includes audit.metadata["changed"], "requires_shipping"
    get admin_edit_shop_item_path("poster")
    assert_select "input[type=checkbox][name='shop_item[requires_shipping]']:not([checked])"
  end
end
