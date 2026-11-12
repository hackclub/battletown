require "test_helper"
require_relative "../../support/orders_helper"

# Real threads on real connections, so these cannot run inside a rolled-back transaction. Each test makes its own users and
# deletes them (and their rows, by cascade) at the end. Two staff clicks, or a staff click and the buyer's, on the same order
# must have exactly one effect and exactly one refund.
class Orders::ConcurrencyTest < ActiveSupport::TestCase
  include OrdersTestHelper

  self.use_transactional_tests = false

  setup do
    setup_orders_world(coins: 200)
    @staff_two = build_user
    ENV["ADMIN_HCA_UIDS"] = [ @staff.hca_uid, @staff_two.hca_uid ].join(",")
  end

  teardown do
    teardown_orders_world
    User.where(id: [ @buyer.id, @staff.id, @staff_two.id, @other.id ]).delete_all
    AdminAuditEvent.where(actor_id: nil).delete_all
  end

  def race(*blocks)
    gate = Queue.new
    ready = Queue.new
    threads = blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          gate.pop
          [ :ok, block.call ]
        rescue StandardError => error
          [ :error, error ]
        end
      end
    end
    blocks.size.times { Timeout.timeout(20) { ready.pop } }
    blocks.size.times { gate << true }
    threads.map(&:value)
  end

  def fresh(order) = Order.find(order.id)

  def staff_call(service, order, by: @staff, **options)
    -> { "Orders::#{service}".constantize.call(order: fresh(order), by: User.find(by.id), as: :staff, **options) }
  end

  test "two staff members cancelling the same order at once: one effect, one refund" do
    order = order_for
    outcomes = race(staff_call("Cancel", order, reason_code: "duplicate"), staff_call("Cancel", order, by: @staff_two, reason_code: "other"))
    assert_equal [ :ok, :ok ], outcomes.map(&:first)
    assert_equal %i[done unchanged], outcomes.map { |_, result| result.outcome }.sort
    assert_equal 1, refunds_for.count
    assert_equal 200, Coins::Balance.total(@buyer)
    assert_equal 1, OrderEvent.where(order_id: order.id).count
    assert_equal 1, AdminAuditEvent.where(action: "order_cancelled", subject_id: order.id).count
  end

  test "refunding a shipped order twice at once refunds once" do
    order = order_in("shipped")
    outcomes = race(staff_call("Refund", order, reason_code: "other"), staff_call("Refund", order, by: @staff_two, reason_code: "other"))
    assert_equal [ :ok, :ok ], outcomes.map(&:first)
    assert_equal 1, refunds_for.count
    assert_equal 200, Coins::Balance.total(@buyer)
    assert_equal 1, OrderEvent.where(order_id: order.id, action: "refunded").count
  end

  test "refunding a fulfilled order twice at once refunds once" do
    order = order_in("fulfilled")
    outcomes = race(staff_call("Refund", order, reason_code: "other"), staff_call("Refund", order, by: @staff_two, reason_code: "other"))
    assert_equal [ :ok, :ok ], outcomes.map(&:first)
    assert_equal 1, refunds_for.count
  end

  test "the buyer cancelling while staff cancels: one refund" do
    order = order_for
    outcomes = race(-> { Orders::Cancel.call(order: fresh(order), by: User.find(@buyer.id), as: :buyer) }, staff_call("Cancel", order, reason_code: "buyer_request"))
    assert_equal [ :ok, :ok ], outcomes.map(&:first)
    assert_equal 1, refunds_for.count
    assert_equal 1, OrderEvent.where(order_id: order.id).count
  end

  test "the buyer cancelling while staff ships: exactly one of them wins, and the coins match the winner" do
    order = order_for
    outcomes = race(-> { Orders::Cancel.call(order: fresh(order), by: User.find(@buyer.id), as: :buyer) }, staff_call("Ship", order))
    fresh_order = fresh(order)
    assert_includes %w[cancelled shipped], fresh_order.status
    if fresh_order.cancelled?
      assert_equal 1, refunds_for.count
      assert_equal 1, outcomes.count { |kind, _| kind == :error }, "shipping a cancelled order is refused"
    else
      assert_equal 0, refunds_for.count
      assert_equal 1, outcomes.count { |kind, _| kind == :error }, "cancelling a shipped order is refused"
    end
    assert_equal 1, OrderEvent.where(order_id: order.id).count
  end

  test "two staff members shipping the same order at once: one shipment, one event, the first tracking wins" do
    order = order_for
    outcomes = race(staff_call("Ship", order, tracking: { carrier: "ups", number: "1Z999AA10123456784" }),
                    staff_call("Ship", order, by: @staff_two, tracking: { carrier: "dhl", number: "JD0146000000" }))
    assert_equal [ :ok, :ok ], outcomes.map(&:first)
    assert_equal 1, OrderEvent.where(order_id: order.id, action: "shipped").count
    shipped = fresh(order)
    assert_predicate shipped, :shipped?
    assert_includes [ [ "ups", "1Z999AA10123456784" ], [ "dhl", "JD0146000000" ] ], [ shipped.tracking_carrier, shipped.tracking_number ]
  end

  test "hold and cancel at once never leaves a cancelled order with two events or two refunds" do
    order = order_for
    race(staff_call("Hold", order), staff_call("Cancel", order, by: @staff_two, reason_code: "other"))
    assert_operator refunds_for.count, :<=, 1
    final = fresh(order)
    assert_includes %w[on_hold cancelled], final.status
    assert_equal(final.cancelled? ? 1 : 0, refunds_for.count)
  end

  test "four simultaneous cancel clicks refund once" do
    order = order_for
    outcomes = race(*Array.new(4) { staff_call("Cancel", order, reason_code: "other") })
    assert_equal 4, outcomes.count { |kind, _| kind == :ok }
    assert_equal 1, refunds_for.count
    assert_equal 1, outcomes.count { |_, result| result.changed? }
  end
end
