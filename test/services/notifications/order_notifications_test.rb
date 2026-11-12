require "test_helper"
require_relative "../../support/orders_helper"
require_relative "../../support/notifications_helper"
require_relative "../../support/email_helper"

# The buyer's order messages (order_shipped, order_fulfilled, order_cancelled, order_refunded): when a row is queued, what the
# text says, and everything that stops it. Nothing real is sent (a fake adapter), and no text ever holds a tracking number.
class Notifications::OrderNotificationsTest < ActiveSupport::TestCase
  include OrdersTestHelper
  include NotificationsHelper
  include EmailHelper

  NOON = Time.utc(2026, 11, 10, 12)
  APP = "https://battletown.example"
  TRACKING = "1Z999AA10123456784".freeze

  setup do
    travel_to NOON
    setup_orders_world(coins: 1000)
    @buyer.update_columns(email: "teen-orders@example.test")
  end

  teardown do
    teardown_orders_world
    travel_back
  end

  def rows(kind = nil, channel: "slack_dm")
    scope = Notification.where(user_id: @buyer.id, channel: channel)
    kind ? scope.where(kind: kind) : scope
  end

  def text_for(row) = with_env("APP_URL" => APP) { Notifications::Message.build(row, @buyer.reload) }

  def run_dispatcher(adapter, now: NOON + 1.minute, enabled: "true")
    with_env("NOTIFICATIONS_ENABLED" => enabled, "APP_URL" => APP) do
      Notifications::Dispatcher.run(now: now, adapter: adapter, config: Notifications::Config.current)
    end
  end

  test "the four kinds exist, with a template, a settings label and the database allows them" do
    kinds = %w[order_shipped order_fulfilled order_cancelled order_refunded]
    config = Notifications::Config.current
    kinds.each do |kind|
      assert_includes Notification::KINDS, kind
      assert_includes Notification::EVENT_KINDS, kind
      assert config.template(kind).present?, kind
      assert config.label(kind)["title"].present?, kind
      assert config.label(kind)["hint"].present?, kind
      assert_operator config.template(kind).length, :<=, 280
      assert_no_match(/hackclub|HackClub|hack club/, config.template(kind))
      assert_not_includes config.template(kind), "{tracking}", "no tracking placeholder, ever"
      assert_no_match(/\{(reason|note|tracking|carrier|number)\}/, config.template(kind))
    end
    assert Notification.new(user: @buyer, kind: "order_shipped", subject_id: 1, scheduled_for: NOON, due_at: NOON, idempotency_key: "k1").valid?
    NotificationPreference.create!(user: @buyer, kind: "order_refunded", enabled: false)
  end

  test "staff shipping, fulfilling, cancelling and refunding each queue exactly one message for the buyer" do
    shipped = order_for
    Orders::Ship.call(order: shipped, by: @staff, as: :staff, tracking: { carrier: "ups", number: TRACKING })
    fulfilled = order_for
    Orders::Fulfil.call(order: fulfilled, by: @staff, as: :staff)
    cancelled = order_for
    Orders::Cancel.call(order: cancelled, by: @staff, as: :staff, reason_code: "out_of_stock")
    refunded = order_for
    Orders::Ship.call(order: refunded, by: @staff, as: :staff)
    Orders::Refund.call(order: refunded, by: @staff, as: :staff, reason_code: "other")

    assert_equal [ shipped.id ], rows("order_shipped").where(subject_id: shipped.id).pluck(:subject_id)
    assert_equal [ fulfilled.id ], rows("order_fulfilled").pluck(:subject_id)
    assert_equal [ cancelled.id ], rows("order_cancelled").pluck(:subject_id)
    assert_equal [ refunded.id ], rows("order_refunded").pluck(:subject_id)
    assert_equal [ "order:#{shipped.id}:order_shipped", "order:#{refunded.id}:order_shipped" ].sort, rows("order_shipped").pluck(:idempotency_key).sort
    assert_equal "order:#{cancelled.id}:order_cancelled", rows("order_cancelled").sole.idempotency_key
    assert rows.all?(&:pending?)
  end

  test "a repeated move or a repeated event never queues a second message" do
    order = order_for
    Orders::Ship.call(order: order, by: @staff, as: :staff)
    Orders::Ship.call(order: Order.find(order.id), by: @staff, as: :staff)
    3.times { ActiveSupport::Notifications.instrument("order_shipped.battletown", order_id: order.id, actor_kind: "staff") }
    assert_equal 1, rows("order_shipped").count
  end

  test "a hold and a release send nothing" do
    order = order_for
    Orders::Hold.call(order: order, by: @staff, as: :staff)
    Orders::Release.call(order: order, by: @staff, as: :staff)
    Orders::AddNote.call(order: order, by: @staff, note: "hi")
    assert_empty rows
  end

  test "the buyer cancelling their own order gets no message about it" do
    Orders::Cancel.call(order: order_for, by: @buyer, as: :buyer)
    assert_empty rows
  end

  test "someone with no Slack id, or with the kind switched off, gets nothing; others are not affected" do
    @buyer.update_columns(slack_id: nil)
    Orders::Ship.call(order: order_for, by: @staff, as: :staff)
    assert_empty rows

    @buyer.update_columns(slack_id: "U0ORDERBUY")
    Notifications::Preferences.update!(@buyer, "order_fulfilled" => "0")
    Orders::Fulfil.call(order: order_for, by: @staff, as: :staff)
    assert_empty rows("order_fulfilled")
    Orders::Ship.call(order: order_for, by: @staff, as: :staff)
    assert_equal 1, rows("order_shipped").count
  end

  test "an un-onboarded buyer gets nothing" do
    @buyer.update_columns(onboarded_at: nil)
    Orders::Ship.call(order: order_for, by: @staff, as: :staff)
    assert_empty rows
  end

  test "a failure in the handler never breaks the staff action" do
    order = order_for
    original = Notifications::Outbox.method(:enqueue)
    Notifications::Outbox.define_singleton_method(:enqueue) { |**| raise "boom" }
    begin
      logs = capture_logs { Orders::Ship.call(order: order, by: @staff, as: :staff) }
      assert_match(/notifications.trigger error=RuntimeError event=order_shipped/, logs)
      assert_no_match(/boom/, logs)
    ensure
      Notifications::Outbox.define_singleton_method(:enqueue, original)
    end
    assert_predicate order.reload, :shipped?
  end

  # --- text ---

  test "shipped says the item and links to the order page, and never the tracking number, carrier, note or reason" do
    order = order_for
    Orders::Ship.call(order: order, by: @staff, as: :staff, tracking: { carrier: "ups", number: TRACKING }, note: "Packed in a blue box")
    text = text_for(rows("order_shipped").sole)
    assert_includes text, "Battletown T-shirt"
    assert_includes text, "#{APP}/shop/orders/#{order.id}"
    [ TRACKING, "ups", "UPS", "blue box", "tracking" ].each { |leak| assert_not_includes text, leak }
    assert_no_match(/\{|\}/, text)
  end

  test "fulfilled links to the order page" do
    order = order_for
    Orders::Fulfil.call(order: order, by: @staff, as: :staff)
    text = text_for(rows("order_fulfilled").sole)
    assert_includes text, "handed over"
    assert_includes text, "#{APP}/shop/orders/#{order.id}"
  end

  test "cancelled and refunded say how many coins came back, but not why" do
    cancelled = order_for
    Orders::Cancel.call(order: cancelled, by: @staff, as: :staff, reason_code: "fraud_abuse", note: "Resale account")
    text = text_for(rows("order_cancelled").sole)
    assert_includes text, "was cancelled. Your 50 coins are back."
    refunded = order_for
    Orders::Ship.call(order: refunded, by: @staff, as: :staff)
    Orders::Refund.call(order: refunded, by: @staff, as: :staff, reason_code: "address_problem", note: "Lost parcel")
    text_two = text_for(rows("order_refunded").sole)
    assert_includes text_two, "was refunded. Your 50 coins are back."
    [ text, text_two ].each { |body| assert_no_match(/fraud|resale|lost|address|reason|staff/i, body) }
  end

  test "a free sticker order's message does not promise coins back" do
    sticker = Shop::ClaimSticker.call(user: @buyer)
    Orders::Cancel.call(order: sticker, by: @staff, as: :staff, reason_code: "other")
    text = text_for(rows("order_cancelled").sole)
    assert_no_match(/coins/, text)
    assert_includes text, "Free Battletown sticker"
  end

  test "an item name cannot open a Slack mention or link" do
    order = order_for
    order.update_columns(prize_name: "<!channel> & <https://evil.example|click>")
    Orders::Fulfil.call(order: Order.find(order.id), by: @staff, as: :staff)
    text = text_for(rows("order_fulfilled").sole)
    assert_includes text, "&lt;!channel&gt; &amp; &lt;https://evil.example|click&gt;"
    assert_no_match(/<!channel>|<https/, text)
  end

  test "a message whose order has moved on is dropped rather than sent stale" do
    order = order_for
    Orders::Ship.call(order: order, by: @staff, as: :staff)
    row = rows("order_shipped").sole
    Orders::Refund.call(order: order, by: @staff, as: :staff, reason_code: "other")
    assert_nil text_for(row), "refunded is no longer 'shipped'"
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls.select { |call| call[:text].to_s.include?("has shipped") }
    assert_equal "subject_gone", row.reload.last_error_code

    other = order_for
    Orders::Ship.call(order: other, by: @staff, as: :staff)
    Orders::Fulfil.call(order: other, by: @staff, as: :staff)
    assert_not_nil text_for(rows("order_shipped").find_by!(subject_id: other.id)), "shipped then fulfilled is still true of 'shipped'"
  end

  test "another person's order id never produces a message for someone else" do
    give_coins(@other, 100)
    order = order_for(@other)
    row = Notification.create!(user: @buyer, kind: "order_shipped", subject_id: order.id, scheduled_for: NOON, due_at: NOON, idempotency_key: "cross-1")
    assert_nil text_for(row)
  end

  # --- delivery ---

  test "the dispatcher sends it through the adapter once; the kill switch keeps everything dark" do
    order = order_for
    Orders::Ship.call(order: order, by: @staff, as: :staff, tracking: { carrier: "ups", number: TRACKING })
    off = NotificationsHelper::FakeAdapter.new
    [ nil, "false", "" ].each { |value| run_dispatcher(off, enabled: value) }
    assert_empty off.calls
    assert_predicate rows("order_shipped").sole, :pending?

    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    assert_equal 1, adapter.calls.size
    assert_equal "U0ORDERBUY", adapter.calls.first[:slack_id]
    assert_not_includes adapter.calls.first[:text], TRACKING
    run_dispatcher(adapter)
    assert_equal 1, adapter.calls.size
    assert_predicate rows("order_shipped").sole, :sent?
  end

  test "an opt-out after queueing is respected at send time" do
    Orders::Ship.call(order: order_for, by: @staff, as: :staff)
    Notifications::Preferences.update!(@buyer, "order_shipped" => "0")
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert_equal "opted_out", rows("order_shipped").sole.last_error_code
  end

  test "quiet hours move the message to the end of the quiet window" do
    travel_to Time.utc(2026, 11, 10, 22, 30) do
      Orders::Ship.call(order: order_for, by: @staff, as: :staff)
      adapter = NotificationsHelper::FakeAdapter.new
      with_env("NOTIFICATIONS_ENABLED" => "true", "APP_URL" => APP) do
        Notifications::Dispatcher.run(now: Time.utc(2026, 11, 10, 23, 0), adapter: adapter, config: Notifications::Config.current)
      end
      assert_empty adapter.calls
      assert_equal Time.utc(2026, 11, 11, 7, 0), rows("order_shipped").sole.due_at
    end
  end

  test "the outbox row holds no text, no tracking number and no address" do
    Orders::Ship.call(order: order_for, by: @staff, as: :staff, tracking: { carrier: "ups", number: TRACKING })
    row = rows("order_shipped").sole
    assert_not_includes row.attributes.values.map(&:to_s).join(" "), TRACKING
    assert_not_includes row.attributes.values.map(&:to_s).join(" "), "U0ORDERBUY"
  end

  test "the settings page lists the four order messages with plain labels" do
    config = Notifications::Config.current
    assert_equal "Order shipped", config.label("order_shipped")["title"]
    assert_equal %w[order_shipped order_fulfilled order_cancelled order_refunded], Notifications::Preferences.visible_settings(@buyer).keys.last(4)
  end

  # --- email (behind the `email` flag) ---

  test "with the email flag on, shipping also queues one email row; fulfilment and the others stay Slack-only; with it off, none" do
    with_feature(:email) do
      order = order_for
      Orders::Ship.call(order: order, by: @staff, as: :staff, tracking: { carrier: "ups", number: TRACKING })
      Orders::Fulfil.call(order: order, by: @staff, as: :staff)
      Orders::Cancel.call(order: order_for, by: @staff, as: :staff, reason_code: "other")
      email = rows(channel: "email")
      assert_equal [ "order_shipped" ], email.pluck(:kind)
      assert_equal "email:order:#{order.id}:order_shipped", email.sole.idempotency_key
      assert_equal order.id, email.sole.subject_id
      assert_not_includes email.sole.attributes.values.map(&:to_s).join(" "), TRACKING
      ActiveSupport::Notifications.instrument("order_shipped.battletown", order_id: order.id, actor_kind: "staff")
      assert_equal 1, rows(channel: "email").count
    end
    without_feature(:email) do
      Orders::Ship.call(order: order_for, by: @staff, as: :staff)
      assert_equal 1, rows(channel: "email").count, "still only the one from before"
    end
  end

  test "the shipped email says the item and links to the order page, never the tracking number" do
    with_feature(:email) do
      order = order_for
      Orders::Ship.call(order: order, by: @staff, as: :staff, tracking: { carrier: "ups", number: TRACKING })
      row = rows(channel: "email").sole
      values = Notifications::Email::Content.build(row, @buyer)
      assert_equal({ item: "Battletown T-shirt", link: "#{Notifications::Links.base}/shop/orders/#{order.id}" }, values)
      mail = with_env("APP_URL" => APP, "MAIL_FROM" => "Battletown <noreply@example.test>") do
        NotificationMailer.with(user: @buyer, values: values).order_shipped.message
      end
      assert_equal "Your Battletown T-shirt order has shipped", mail.subject
      [ mail.text_part.body.to_s, mail.html_part.body.to_s ].each do |body|
        assert_not_includes body, TRACKING
        assert_includes body, "/shop/orders/#{order.id}"
      end
    end
  end

  test "an emailed message for an order that was refunded meanwhile is dropped" do
    with_feature(:email) do
      order = order_for
      Orders::Ship.call(order: order, by: @staff, as: :staff)
      row = rows(channel: "email").sole
      Orders::Refund.call(order: order, by: @staff, as: :staff, reason_code: "other")
      assert_nil Notifications::Email::Content.build(row, @buyer)
    end
  end
end
