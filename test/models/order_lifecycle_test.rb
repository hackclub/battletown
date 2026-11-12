require "test_helper"
require_relative "../support/orders_helper"
require Rails.root.join("db/migrate/20261113140000_add_order_lifecycle").to_s

# The data side of the order lifecycle: the six statuses and tracking columns on orders, the order_events table, their database
# checks (even by raw SQL), the old rows after the migration, and what a data-deletion request does with the history.
class OrderLifecycleTest < ActiveSupport::TestCase
  include OrdersTestHelper

  setup { setup_orders_world }
  teardown { teardown_orders_world }

  def raw_order(status: "requested", key: "raw-#{SecureRandom.hex(4)}", **columns)
    values = { user_id: @buyer.id, prize_key: "tshirt", prize_name: "Name", coins: 50, kind: "purchase", status: status, idempotency_key: key,
               created_at: Time.current, updated_at: Time.current }.merge(columns)
    quoted = values.transform_values { |value| Order.connection.quote(value) }
    Order.transaction(requires_new: true) do
      Order.connection.execute("INSERT INTO orders (#{quoted.keys.join(', ')}) VALUES (#{quoted.values.join(', ')}) RETURNING id").first.fetch("id")
    end
  end

  def raw_event(order_id, **columns)
    values = { order_id: order_id, actor_kind: "staff", action: "note_added", from_status: "requested", to_status: "requested", created_at: Time.current }.merge(columns)
    quoted = values.transform_values { |value| Order.connection.quote(value) }
    Order.transaction(requires_new: true) { Order.connection.execute("INSERT INTO order_events (#{quoted.keys.join(', ')}) VALUES (#{quoted.values.join(', ')})") }
  end

  def refused(&block) = assert_raises(ActiveRecord::StatementInvalid, &block)

  # --- statuses ---

  test "the six statuses, in order, with predicates and the open ones" do
    assert_equal %w[requested on_hold shipped fulfilled cancelled refunded], Order::STATUSES
    assert_equal %w[requested on_hold shipped], Order::OPEN_STATUSES
    Order::STATUSES.each do |status|
      order = Order.new(status: status)
      assert order.public_send(:"#{status}?")
    end
    assert_equal "requested", Order.new(status: "on_hold").buyer_status
    assert_equal "shipped", Order.new(status: "shipped").buyer_status
  end

  test "the queue scope puts requested, then on hold, then shipped, then everything else" do
    statuses = Order::STATUSES.shuffle.map { |status| order_in(status) }
    assert_equal %w[requested on_hold shipped], Order.where(id: statuses.map(&:id)).queue_order.first(3).map(&:status)
    assert_equal 3, Order.where(id: statuses.map(&:id)).unfinished.count
  end

  test "the database knows the six statuses and refuses others" do
    %w[requested on_hold fulfilled].each { |status| assert raw_order(status: status, fulfilled_at: (Time.current if status == "fulfilled")) }
    assert raw_order(status: "shipped", shipped_at: Time.current)
    assert raw_order(status: "cancelled", cancelled_at: Time.current)
    assert raw_order(status: "refunded", refunded_at: Time.current)
    refused { raw_order(status: "lost") }
    refused { raw_order(status: "awaiting_address") }
  end

  test "the timestamps must agree with the status in the database" do
    refused { raw_order(status: "shipped") }
    refused { raw_order(status: "refunded") }
    refused { raw_order(status: "cancelled") }
    refused { raw_order(status: "fulfilled") }
    refused { raw_order(status: "requested", refunded_at: Time.current) }
    refused { raw_order(status: "requested", shipped_at: Time.current) }
    refused { raw_order(status: "on_hold", fulfilled_at: Time.current) }
    refused { raw_order(status: "cancelled", cancelled_at: Time.current, fulfilled_at: Time.current) }
    assert raw_order(status: "refunded", refunded_at: Time.current, fulfilled_at: Time.current), "a fulfilled order that is refunded later keeps fulfilled_at"
    assert raw_order(status: "fulfilled", fulfilled_at: Time.current, shipped_at: Time.current), "shipped then fulfilled keeps shipped_at"
  end

  test "tracking is checked in the database: a pair, a plain number, a short label only for other, and only once shipped" do
    now = Time.current
    assert raw_order(status: "shipped", shipped_at: now, tracking_carrier: "ups", tracking_number: "1Z999AA10123456784")
    assert raw_order(status: "shipped", shipped_at: now, tracking_carrier: "other", tracking_number: "ABC 123-456", tracking_label: "Local courier")
    refused { raw_order(status: "shipped", shipped_at: now, tracking_carrier: "ups") }
    refused { raw_order(status: "shipped", shipped_at: now, tracking_number: "1Z999AA10123456784") }
    refused { raw_order(status: "shipped", shipped_at: now, tracking_carrier: "UPS", tracking_number: "1Z999AA10123456784") }
    refused { raw_order(status: "shipped", shipped_at: now, tracking_carrier: "ups", tracking_number: "1Z<script>") }
    refused { raw_order(status: "shipped", shipped_at: now, tracking_carrier: "ups", tracking_number: "ab") }
    refused { raw_order(status: "shipped", shipped_at: now, tracking_carrier: "ups", tracking_number: "javascript:alert(1)") }
    refused { raw_order(status: "shipped", shipped_at: now, tracking_carrier: "ups", tracking_number: "1Z999AA10123456784", tracking_label: "Nope") }
    refused { raw_order(status: "shipped", shipped_at: now, tracking_carrier: "other", tracking_number: "ABC123456", tracking_label: "x" * 41) }
    refused { raw_order(status: "requested", tracking_carrier: "ups", tracking_number: "1Z999AA10123456784") }
  end

  test "the model validates tracking the same way" do
    base = { shipped_at: Time.current }
    assert order_with(base.merge(tracking_carrier: "ups", tracking_number: "1Z999AA10123456784")).valid?
    assert order_with(base).valid?, "no tracking at all is fine"
    [ { tracking_carrier: "ups" }, { tracking_number: "1Z999AA10123456784" }, { tracking_carrier: "pigeon", tracking_number: "ABC123456" },
      { tracking_carrier: "ups", tracking_number: "bad<>" }, { tracking_carrier: "ups", tracking_number: "1Z999AA10123456784", tracking_label: "L" },
      { tracking_carrier: "other", tracking_number: "ABC123456", tracking_label: "L" * 41 }, { tracking_label: "Alone" } ].each do |tracking|
      assert_not order_with(base.merge(tracking)).valid?, tracking.inspect
    end
    assert_not order_with(tracking_carrier: "ups", tracking_number: "1Z999AA10123456784").valid?, "tracking needs shipped_at"
  end

  def order_with(attributes)
    Order.new({ user: @buyer, prize_key: "tshirt", prize_name: "T", coins: 50, kind: "purchase", idempotency_key: "m-#{SecureRandom.hex(3)}", status: "shipped" }.merge(attributes))
  end

  test "age and overdue" do
    order = Order.new(created_at: 8.days.ago, status: "requested")
    assert_equal 8, order.age_days
    assert_predicate order, :overdue?
    assert_not Order.new(created_at: 6.days.ago, status: "requested").overdue?
    assert_equal 7, Orders::Config.current.overdue_days
    assert_equal 0, Order.new(created_at: 1.hour.from_now).age_days, "never negative"
  end

  # --- history table ---

  test "an event needs a real action, actor kind and statuses, and the database says the same" do
    order = order_for
    event = OrderEvent.new(order: order, actor_kind: "staff", action: "held", from_status: "requested", to_status: "on_hold")
    assert_predicate event, :valid?
    [ { action: "lost" }, { actor_kind: "robot" }, { from_status: "nope" }, { to_status: "nope" }, { reason_code: "Not Valid" }, { note: "n" * 301 } ].each do |bad|
      assert_not OrderEvent.new(order: order, actor_kind: "staff", action: "held", **bad).valid?, bad.inspect
    end
    assert_not OrderEvent.new(order: order, actor_kind: "staff", action: "note_added").valid?, "a note needs text"
    assert_not OrderEvent.new(order: order, actor_kind: "buyer", actor: @buyer, action: "cancelled").valid?, "only staff are recorded by id"

    refused { raw_event(order.id, action: "lost") }
    refused { raw_event(order.id, actor_kind: "robot") }
    refused { raw_event(order.id, from_status: "nope") }
    refused { raw_event(order.id, to_status: "nope") }
    refused { raw_event(order.id, reason_code: "Bad Code") }
    refused { raw_event(order.id, note: "n" * 301) }
    refused { raw_event(order.id, note: "") }
    refused { raw_event(order.id, note: "bell\u0007") }
    refused { raw_event(order.id, actor_kind: "buyer", actor_id: @buyer.id) }
    refused { raw_event(order.id, actor_kind: "system", actor_id: @staff.id) }
    refused { raw_event(0) }
    assert raw_event(order.id, actor_kind: "staff", actor_id: @staff.id, note: "n" * 300)
    assert raw_event(order.id, actor_kind: "system")
  end

  test "deleting the order deletes its history; deleting a staff member keeps the history with no actor" do
    order = order_for
    Orders::Hold.call(order: order, by: @staff, as: :staff)
    event = order.events.sole
    assert_equal @staff.id, event.actor_id
    @staff.destroy!
    assert_nil event.reload.actor_id
    assert_equal "staff", event.actor_kind
    assert_difference -> { OrderEvent.count }, -1 do
      Order.where(id: order.id).delete_all
    end
  end

  test "a data-deletion request deletes the order history with the person and the counts include it" do
    order = order_for
    Orders::Ship.call(order: order, by: @staff, as: :staff, tracking: { carrier: "ups", number: "1Z999AA10123456784" })
    Orders::AddNote.call(order: order, by: @staff, note: "Staff note")
    Orders::Cancel.call(order: order_for, by: @buyer, as: :buyer)
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: @buyer.hca_uid)

    dry = Privacy::Deleter.new(subject).call(dry_run: true).deleted
    assert_equal 3, dry["order_events"]
    assert_equal 2, dry["orders"]
    assert_equal 3, OrderEvent.count, "a dry run rolls back"

    real = Privacy::Deleter.new(subject).call(dry_run: false).deleted
    assert_equal 3, real["order_events"]
    assert_equal 0, OrderEvent.where(order_id: order.id).count
    assert_equal 0, Order.where(user_id: @buyer.id).count
    assert User.exists?(@staff.id), "the staff member is not deleted with the buyer"
  end

  test "history is read in order with an index on order and time" do
    order = order_for
    Orders::Hold.call(order: order, by: @staff, as: :staff)
    Orders::Release.call(order: order, by: @staff, as: :staff)
    assert_equal %w[held released], order.events.oldest_first.pluck(:action)
    assert_equal %w[released held], order.events.newest_first.pluck(:action)
    assert_equal [ "order_id", "created_at" ], ActiveRecord::Base.connection.indexes(:order_events).find { |index| index.columns == %w[order_id created_at] }.columns
  end

  # --- old rows ---

  test "rows from before the lifecycle keep their status and meaning (requested, fulfilled, cancelled)" do
    requested = raw_order
    fulfilled = raw_order(status: "fulfilled", fulfilled_at: Time.current)
    cancelled = raw_order(status: "cancelled", cancelled_at: Time.current)
    assert_equal %w[requested fulfilled cancelled], Order.where(id: [ requested, fulfilled, cancelled ]).order(:id).pluck(:status)
    assert Order.find(fulfilled).fulfilled?
    assert_nil Order.find(fulfilled).shipped_at
    assert_nil Order.find(requested).tracking_number
    assert_equal 0, OrderEvent.where(order_id: [ requested, fulfilled, cancelled ]).count, "old orders have no history; the page shows only the order date"
  end

  test "the lifecycle migration upgrades old rows untouched, and reverses them sensibly" do
    migration = AddOrderLifecycle.new
    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:down)
      Order.reset_column_information
      now = Time.current
      Order.connection.execute(<<~SQL)
        INSERT INTO orders (user_id, prize_key, prize_name, coins, kind, status, idempotency_key, fulfilled_at, cancelled_at, created_at, updated_at) VALUES
          (#{@buyer.id}, 'tshirt', 'A', 50, 'purchase', 'requested', 'old-1', NULL, NULL, '#{now.to_fs(:db)}', '#{now.to_fs(:db)}'),
          (#{@buyer.id}, 'tshirt', 'B', 50, 'purchase', 'fulfilled', 'old-2', '#{now.to_fs(:db)}', NULL, '#{now.to_fs(:db)}', '#{now.to_fs(:db)}'),
          (#{@buyer.id}, 'tshirt', 'C', 50, 'purchase', 'cancelled', 'old-3', NULL, '#{now.to_fs(:db)}', '#{now.to_fs(:db)}', '#{now.to_fs(:db)}')
      SQL
      migration.migrate(:up)
      Order.reset_column_information
      rows = Order.where(idempotency_key: %w[old-1 old-2 old-3]).order(:idempotency_key)
      assert_equal %w[requested fulfilled cancelled], rows.map(&:status)
      assert_equal [ nil, nil, nil ], rows.map(&:shipped_at)
      assert_equal [ nil, nil, nil ], rows.map(&:tracking_number)
      assert_not_nil rows.second.fulfilled_at
      assert_not_nil rows.third.cancelled_at

      # And the other way: a shipped order goes back to requested, a refunded one to cancelled.
      shipped = Order.create!(user: @buyer, prize_key: "tshirt", prize_name: "S", coins: 50, kind: "purchase", idempotency_key: "new-1", status: "shipped", shipped_at: now)
      refunded = Order.create!(user: @buyer, prize_key: "tshirt", prize_name: "R", coins: 50, kind: "purchase", idempotency_key: "new-2", status: "refunded", refunded_at: now)
      migration.migrate(:down)
      Order.reset_column_information
      assert_equal [ "requested", "cancelled" ], Order.where(id: [ shipped.id, refunded.id ]).order(:id).pluck(:status)
      migration.migrate(:up)
      Order.reset_column_information
    end
  end
end
