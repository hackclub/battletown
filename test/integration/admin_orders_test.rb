require "test_helper"
require_relative "../support/orders_helper"
require_relative "../support/admin_sign_in"
require "csv"

# The staff queue, one order's page and every staff write, as a signed-in admin sees them.
class AdminOrdersTest < ActionDispatch::IntegrationTest
  include OrdersTestHelper
  include AdminSignIn

  setup do
    setup_orders_world(coins: 1000)
    @buyer.update_columns(created_at: Time.utc(2026, 11, 1, 12))
    @waiting = order_for(@buyer, prize: "tshirt")
    @sticker = Shop::ClaimSticker.call(user: @other)
    @done = order_for(@buyer, prize: "custom_sticker")
    Orders::Fulfil.call(order: @done, by: @staff, as: :staff)
  end

  teardown { teardown_orders_world }

  def as_staff
    ENV["ADMIN_HCA_UIDS"] = @staff.hca_uid
    sign_in_as @staff
  end

  # --- who may open it ---

  test "signed-out visitors and non-admins get a 404 on every orders route, and nothing changes" do
    calls = [ [ :get, admin_orders_path ], [ :get, admin_order_path(@waiting) ], [ :post, export_admin_orders_path ] ]
    %w[hold release ship fulfil cancel refund tracking].each { |action| calls << [ :patch, send("#{action}_admin_order_path", @waiting) ] }
    calls << [ :post, note_admin_order_path(@waiting) ]

    [ nil, @buyer ].each do |visitor|
      sign_in_as visitor if visitor
      calls.each do |verb, path|
        public_send(verb, path, params: { reason_code: "other", confirm: "cancel", note: "x" })
        assert_response :not_found, "#{verb} #{path} for #{visitor ? 'a buyer' : 'a visitor'}"
      end
    end
    assert_predicate @waiting.reload, :requested?
    assert_equal 0, refunds_for.count
    assert_equal 0, AdminAuditEvent.where("action LIKE 'order_%'").where.not(action: "order_fulfilled").count
  end

  # --- the queue ---

  test "the list shows requested first, in an admin tool, with the person's name, Slack id and verification" do
    as_staff
    get admin_orders_path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only"
    assert_select "#requested-count", text: "2"
    rows = css_select("tbody tr").map { |row| row["id"] }
    assert_equal "order-#{@done.id}", rows.last, "the fulfilled order comes after the requested ones"
    assert_select "#order-#{@waiting.id}", text: /Pat Buyer/
    assert_select "#order-#{@waiting.id}", text: /Slack: U0ORDERBUY/
    assert_select "#order-#{@waiting.id}", text: /Identity: verified/
    assert_select "#order-#{@sticker.id}", text: /Identity: /
    assert_select "#order-#{@waiting.id} a", text: "Open"
    assert_select "tbody button", 0, "cancelling needs a reason, so it lives on the order page"
    assert_no_match(/address|@example/i, css_select("tbody").text)
  end

  test "queue order is requested, on hold, shipped, then finished" do
    held = order_in("on_hold")
    shipped = order_in("shipped")
    as_staff
    get admin_orders_path
    rows = css_select("tbody tr").map { |row| row["id"].delete_prefix("order-").to_i }
    assert_equal [ @sticker.id, @waiting.id ].sort, rows.first(2).sort
    assert_equal [ held.id, shipped.id ], rows[2, 2]
    assert_equal @done.id, rows.last
    assert_select "#order-#{held.id} .badge", text: "On hold"
    assert_select "#order-#{shipped.id} .badge", text: "Shipped"
  end

  test "status tabs show a count for each of the six statuses and filter" do
    order_in("on_hold")
    order_in("shipped")
    order_in("cancelled")
    order_in("refunded")
    as_staff
    get admin_orders_path
    tabs = css_select(".admin-filters a").map { |link| link.text.squish }
    assert_equal [ "All (7)", "Requested (2)", "On hold (1)", "Shipped (1)", "Fulfilled (1)", "Cancelled (1)", "Refunded (1)" ], tabs
    assert_select ".admin-filters a[aria-current=page]", text: "All (7)"
    assert_select "#on-hold-count", text: "1"

    { "requested" => 2, "on_hold" => 1, "shipped" => 1, "fulfilled" => 1, "cancelled" => 1, "refunded" => 1 }.each do |status, count|
      get admin_orders_path(status: status)
      assert_select "tbody tr", count
      assert_select ".admin-filters a[aria-current=page]", text: /\A#{OrderStatusHelper::STAFF_STATUS_TEXT.fetch(status)} /
    end
  end

  test "kind filter works, and an unknown status or kind is ignored" do
    as_staff
    get admin_orders_path(kind: "signup_sticker")
    assert_select "tbody tr", 1
    assert_select "#order-#{@sticker.id}"
    get admin_orders_path(status: "requested", kind: "purchase")
    assert_select "tbody tr", 1
    get admin_orders_path(status: "'; drop table orders", kind: "zzz")
    assert_select "tbody tr", 3
    get admin_orders_path(status: [ "requested" ], kind: { a: 1 })
    assert_select "tbody tr", 3
  end

  test "search finds an item by part of its name or an order by its number, never a person" do
    as_staff
    get admin_orders_path(q: "t-shi")
    assert_select "tbody tr", 1
    assert_select "#order-#{@waiting.id}"
    get admin_orders_path(q: "STICKER")
    assert_select "tbody tr", 2
    get admin_orders_path(q: @waiting.id.to_s)
    assert_select "#order-#{@waiting.id}"
    get admin_orders_path(q: "##{@done.id}")
    assert_select "#order-#{@done.id}"
    get admin_orders_path(q: "Pat Buyer")
    assert_select "tbody tr", 0
    get admin_orders_path(q: "U0ORDERBUY")
    assert_select "tbody tr", 0
    get admin_orders_path(q: "100%_")
    assert_response :success
    get admin_orders_path(q: "x" * 500)
    assert_response :success
    assert_select "input[name=q][maxlength]"
    get admin_orders_path(q: "t-shi", status: "fulfilled")
    assert_select "tbody tr", 0
  end

  test "each order shows its age in days and an Overdue chip once a requested order passes the threshold" do
    @waiting.update_columns(created_at: 3.days.ago)
    @sticker.update_columns(created_at: 8.days.ago)
    @done.update_columns(created_at: 30.days.ago)
    as_staff
    get admin_orders_path
    assert_select "#order-#{@waiting.id} td", text: /3 days/
    assert_select "#order-#{@waiting.id} .shop-status--overdue", 0
    assert_select "#order-#{@sticker.id} td", text: /8 days/
    assert_select "#order-#{@sticker.id} .shop-status--overdue", text: "Overdue"
    assert_select "#order-#{@done.id} td", text: /30 days/
    assert_select "#order-#{@done.id} .shop-status--overdue", 0, "a finished order is never overdue"
  end

  test "the overdue threshold comes from the config" do
    @waiting.update_columns(created_at: 3.days.ago)
    as_staff
    with_orders_config(overdue_days: 2) do
      get admin_orders_path
      assert_select "#order-#{@waiting.id} .shop-status--overdue", text: "Overdue"
    end
    with_orders_config(overdue_days: 4) do
      get admin_orders_path
      assert_select "#order-#{@waiting.id} .shop-status--overdue", 0
    end
  end

  test "a held order is not overdue" do
    held = order_in("on_hold")
    held.update_columns(created_at: 40.days.ago)
    assert_not held.overdue?
    assert_predicate order_for.tap { |o| o.update_columns(created_at: 8.days.ago) }, :overdue?
  end

  # --- one order's page ---

  test "the order page shows the facts, the history and only the legal actions" do
    as_staff
    get admin_order_path(@waiting)
    assert_response :success
    assert_select "h1", /Order ##{@waiting.id}/
    assert_select "section[aria-labelledby=order-facts]", text: /Pat Buyer/
    assert_select "section[aria-labelledby=order-facts]", text: /U0ORDERBUY/
    assert_select "form[action='#{hold_admin_order_path(@waiting)}']"
    assert_select "form[action='#{ship_admin_order_path(@waiting)}']"
    assert_select "form[action='#{fulfil_admin_order_path(@waiting)}']"
    assert_select "form[action='#{cancel_admin_order_path(@waiting)}']"
    assert_select "form[action='#{note_admin_order_path(@waiting)}']"
    assert_select "form[action='#{release_admin_order_path(@waiting)}']", 0
    assert_select "form[action='#{refund_admin_order_path(@waiting)}']", 0
    assert_select "form[action='#{tracking_admin_order_path(@waiting)}']", 0
  end

  test "which forms each status offers" do
    as_staff
    expected = {
      "on_hold" => %w[release cancel note], "shipped" => %w[fulfil refund tracking note], "fulfilled" => %w[refund tracking note],
      "cancelled" => %w[note], "refunded" => %w[note]
    }
    expected.each do |status, forms|
      order = order_in(status)
      get admin_order_path(order)
      present = %w[hold release ship fulfil cancel refund tracking note].select { |name| css_select("form[action='#{send("#{name}_admin_order_path", order)}']").any? }
      assert_equal forms.sort, present.sort, status
    end
  end

  test "the cancel and refund forms ask for a reason code and a typed confirmation" do
    as_staff
    get admin_order_path(@waiting)
    assert_select "form[action='#{cancel_admin_order_path(@waiting)}'] select[name=reason_code][required]"
    assert_select "form[action='#{cancel_admin_order_path(@waiting)}'] input[name=confirm][required]"
    reasons = css_select("form[action='#{cancel_admin_order_path(@waiting)}'] select option").map(&:text)
    assert_equal [ "Pick a reason", "Out of stock", "Buyer request", "Delivery problem", "Fraud or abuse", "Duplicate order", "Other" ], reasons
    shipped = order_in("shipped")
    get admin_order_path(shipped)
    assert_select "form[action='#{refund_admin_order_path(shipped)}'] select[name=reason_code][required]"
    assert_select "form[action='#{refund_admin_order_path(shipped)}'] input[name=confirm][required]"
  end

  test "the history lists every change with who, when, the reason and the note, newest first" do
    order = order_in("requested")
    Orders::Hold.call(order: order, by: @staff, as: :staff, note: "Check stock")
    Orders::Release.call(order: order, by: @staff, as: :staff)
    Orders::Cancel.call(order: order, by: @staff, as: :staff, reason_code: "out_of_stock", note: "None left")
    as_staff
    get admin_order_path(order)
    items = css_select(".admin-history li").map { |li| li.text.squish }
    assert_equal 4, items.size
    assert_match(/Cancelled \(requested to cancelled\).*Sam Staff.*Reason: Out of stock.*None left/, items.first)
    assert_match(/Released \(on hold to requested\)/, items[1])
    assert_match(/Held \(requested to on hold\).*Check stock/, items[2])
    assert_match(/Ordered.*the buyer/, items.last)
  end

  test "notes render as text, never as markup" do
    Orders::AddNote.call(order: @waiting, by: @staff, note: "<script>alert(1)</script> <b>bold</b>")
    as_staff
    get admin_order_path(@waiting)
    assert_select ".admin-history script", 0
    assert_select ".admin-history b", 0
    assert_select ".admin-history", text: /<script>alert\(1\)<\/script>/
  end

  # --- the writes ---

  test "hold and release move the order, keep the coins and leave the buyer with 'Requested'" do
    as_staff
    patch hold_admin_order_path(@waiting), params: { note: "Waiting for stock" }
    assert_redirected_to admin_order_path(@waiting)
    assert_predicate @waiting.reload, :on_hold?
    follow_redirect!
    assert_select ".flash--notice", /on hold/i
    patch release_admin_order_path(@waiting)
    assert_predicate @waiting.reload, :requested?
    assert_equal 0, refunds_for.count
    assert_equal %w[order_held order_released], AdminAuditEvent.where(subject_id: @waiting.id).order(:id).pluck(:action)
  end

  test "ship with tracking stores it and shows it on the page; bad tracking is refused with the order left alone" do
    as_staff
    patch ship_admin_order_path(@waiting), params: { tracking: { carrier: "ups", number: "1Z999AA10123456784" } }
    assert_redirected_to admin_order_path(@waiting)
    assert_predicate @waiting.reload, :shipped?
    follow_redirect!
    assert_select "section[aria-labelledby=order-facts] a[href='https://www.ups.com/track?tracknum=1Z999AA10123456784'][rel='noopener noreferrer nofollow']"

    bad = order_for(@buyer, prize: "custom_sticker")
    patch ship_admin_order_path(bad), params: { tracking: { carrier: "ups", number: "<script>" } }
    assert_redirected_to admin_order_path(bad)
    follow_redirect!
    assert_select ".flash--alert", /letters, numbers/
    assert_predicate bad.reload, :requested?
    patch ship_admin_order_path(bad), params: { tracking: "not-a-hash" }
    assert_predicate bad.reload, :shipped?, "a stray tracking param is ignored and the order ships without tracking"
    assert_nil bad.tracking_number
  end

  test "mark fulfilled sets the time once and is safe to repeat" do
    as_staff
    patch fulfil_admin_order_path(@waiting)
    first = @waiting.reload.fulfilled_at
    assert_predicate @waiting, :fulfilled?
    travel 2.hours do
      patch fulfil_admin_order_path(@waiting)
    end
    follow_redirect!
    assert_select ".flash--notice", /Nothing changed/
    assert_equal first, @waiting.reload.fulfilled_at
    assert_equal 1, OrderEvent.where(order: @waiting, action: "fulfilled").count
  end

  test "cancel needs a reason and the typed word, then refunds once" do
    as_staff
    before = Coins::Balance.total(@buyer)
    patch cancel_admin_order_path(@waiting), params: { reason_code: "buyer_request" }
    follow_redirect!
    assert_select ".flash--alert", /Type CANCEL/
    patch cancel_admin_order_path(@waiting), params: { reason_code: "buyer_request", confirm: "nope" }
    assert_predicate @waiting.reload, :requested?
    patch cancel_admin_order_path(@waiting), params: { confirm: "cancel" }
    follow_redirect!
    assert_select ".flash--alert", /Pick a reason/
    assert_predicate @waiting.reload, :requested?
    assert_equal 0, refunds_for.count

    patch cancel_admin_order_path(@waiting), params: { reason_code: "buyer_request", confirm: " Cancel ", note: "They asked" }
    assert_redirected_to admin_order_path(@waiting)
    follow_redirect!
    assert_select ".flash--notice", /Cancelled/
    patch cancel_admin_order_path(@waiting), params: { reason_code: "buyer_request", confirm: "cancel" }
    assert_equal before + 50, Coins::Balance.total(@buyer)
    assert_equal 1, refunds_for.count
    assert_equal [ "cancelled", "buyer_request", "They asked", "staff" ], @waiting.events.last.then { |e| [ e.to_status, e.reason_code, e.note, e.actor_kind ] }
  end

  test "refund after shipping or fulfilment needs a reason and the typed word, and refunds once" do
    as_staff
    shipped = order_in("shipped")
    fulfilled = order_in("fulfilled")
    [ shipped, fulfilled ].each do |order|
      patch refund_admin_order_path(order), params: { reason_code: "other" }
      assert_not_predicate order.reload, :refunded?
      patch refund_admin_order_path(order), params: { reason_code: "other", confirm: "REFUND" }
      assert_predicate order.reload, :refunded?
      patch refund_admin_order_path(order), params: { reason_code: "other", confirm: "REFUND" }
    end
    assert_equal 2, refunds_for.count
  end

  test "an illegal move says why and changes nothing" do
    as_staff
    patch release_admin_order_path(@done)
    follow_redirect!
    assert_select ".flash--alert", /isn't on hold/
    patch hold_admin_order_path(@done)
    assert_predicate @done.reload, :fulfilled?
    patch cancel_admin_order_path(@done), params: { reason_code: "other", confirm: "cancel" }
    follow_redirect!
    assert_select ".flash--alert", /can't be cancelled/
    assert_predicate @done.reload, :fulfilled?
    assert_equal 0, refunds_for.count
  end

  test "the note action adds a staff-only line without changing the status" do
    as_staff
    patch hold_admin_order_path(@waiting)
    post note_admin_order_path(@waiting), params: { note: "Called them on Slack" }
    assert_redirected_to admin_order_path(@waiting)
    assert_predicate @waiting.reload, :on_hold?
    assert_equal "Called them on Slack", @waiting.events.where(action: "note_added").last.note
    post note_admin_order_path(@waiting), params: { note: "" }
    follow_redirect!
    assert_select ".flash--alert", /Write a note/
    assert_equal 1, AdminAuditEvent.where(action: "order_note_added").count
  end

  test "the tracking can be edited after shipping" do
    as_staff
    shipped = order_in("shipped")
    patch tracking_admin_order_path(shipped), params: { tracking: { carrier: "other", number: "ABC 123", label: "Local courier" } }
    assert_redirected_to admin_order_path(shipped)
    assert_equal [ "other", "ABC 123", "Local courier" ], [ shipped.reload.tracking_carrier, shipped.tracking_number, shipped.tracking_label ]
    follow_redirect!
    assert_select "section[aria-labelledby=order-facts]", text: /Local courier/
    assert_select "section[aria-labelledby=order-facts] a", 0
  end

  test "an unknown order id is a 404 for staff" do
    as_staff
    patch fulfil_admin_order_path(0)
    assert_response :not_found
    get admin_order_path(0)
    assert_response :not_found
  end

  test "staff writes need the CSRF token" do
    as_staff
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    begin
      patch hold_admin_order_path(@waiting)
      assert_response :unprocessable_content
      post export_admin_orders_path
      assert_response :unprocessable_content
      assert_predicate @waiting.reload, :requested?
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end

  test "staff writes are rate-limited per address" do
    as_staff
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    limit = Orders::Config.current.staff_actions_per_minute
    travel_to Time.utc(2030, 1, 1, 12, 0, 0) do
      limit.times { post note_admin_order_path(@waiting), params: { note: "n" }, headers: { "REMOTE_ADDR" => "203.0.113.50" } }
      post note_admin_order_path(@waiting), params: { note: "n" }, headers: { "REMOTE_ADDR" => "203.0.113.50" }
      assert_response :too_many_requests
    end
  ensure
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
  end

  # --- CSV ---

  def export(**params)
    post export_admin_orders_path, params: params
    response.body
  end

  test "the CSV has the documented columns and no personal data by default, and is a download" do
    as_staff
    shipped = order_in("shipped")
    body = export
    assert_response :success
    assert_match(%r{\Atext/csv}, response.headers["Content-Type"])
    assert_match(/attachment; filename="orders-\d{8}-\d{4}\.csv"/, response.headers["Content-Disposition"])
    assert_equal "no-store", response.headers["Cache-Control"]
    table = CSV.parse(body, headers: true)
    assert_equal %w[order_id created_at status item_name coins kind tracking_carrier age_days], table.headers
    assert_equal Order.count, table.size
    assert_not_includes body, "Pat Buyer"
    assert_not_includes body, "U0ORDERBUY"
    assert_not_includes body, "1Z999AA10123456784"
    assert_equal "ups", table.find { |row| row["order_id"] == shipped.id.to_s }["tracking_carrier"]
    audit = AdminAuditEvent.where(action: "order_exported").last
    assert_equal [ "orders", 0, @staff.id ], [ audit.subject_type, audit.subject_id, audit.actor_id ]
    assert_equal({ "include_contact" => false, "row_count" => Order.count, "truncated" => false }, audit.metadata)
  end

  test "contact columns only with the checkbox, and that export is audited with the filter and row count" do
    as_staff
    body = export(include_contact: "1", status: "requested", kind: "purchase", q: "shirt")
    table = CSV.parse(body, headers: true)
    assert_equal %w[display_name slack_id], table.headers.last(2)
    assert_equal [ [ "Pat Buyer", "U0ORDERBUY" ] ], table.map { |row| row.values_at("display_name", "slack_id") }
    audit = AdminAuditEvent.where(action: "order_exported").last
    assert_equal({ "filter_status" => "requested", "filter_kind" => "purchase", "filter_query" => "shirt", "include_contact" => true, "row_count" => 1, "truncated" => false },
                 audit.metadata)
    assert_not_includes audit.metadata.to_s, "Pat"
    assert_not_includes audit.metadata.to_s, "U0ORDERBUY"
    export(include_contact: "yes")
    assert_not AdminAuditEvent.where(action: "order_exported").last.metadata["include_contact"], "only the exact checkbox value opts in"
  end

  test "the export respects the filters and the row cap, and says when it was cut" do
    as_staff
    3.times { order_for(@buyer, prize: "custom_sticker") }
    with_orders_config(export_max_rows: 2) do
      body = export
      assert_equal 2, CSV.parse(body, headers: true).size
      assert_equal({ "include_contact" => false, "row_count" => 2, "truncated" => true }, AdminAuditEvent.where(action: "order_exported").last.metadata)
    end
    assert_equal 1, CSV.parse(export(status: "fulfilled"), headers: true).size
  end

  test "a cell that looks like a formula is defused in the download" do
    as_staff
    @waiting.update_columns(prize_name: "=cmd|' /C calc'!A0")
    @buyer.update_columns(display_name: "-2+3", slack_id: "@here")
    body = export(include_contact: "1")
    table = CSV.parse(body, headers: true)
    row = table.find { |r| r["order_id"] == @waiting.id.to_s }
    assert_equal [ "'=cmd|' /C calc'!A0", "'-2+3", "'@here" ], row.values_at("item_name", "display_name", "slack_id")
  end

  # --- dashboard ---

  test "the admin dashboard links to the queue with the requested count, and the held count" do
    order_in("on_hold")
    as_staff
    get admin_root_path
    assert_select "a[href='#{admin_orders_path}']", text: "Shop orders"
    assert_select ".admin-link p", text: /2 requested/
    assert_select ".admin-link p", text: /1 on hold/
  end
end
