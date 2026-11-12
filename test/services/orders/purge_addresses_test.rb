require "test_helper"
require_relative "../../support/orders_helper"
require "rake"

# Keeping an address only as long as the parcel needs it: 30 days after shipped or fulfilled (whichever came first), at once when
# the order is cancelled or refunded (by any route), and with the person or the order. Safe to run twice.
class Orders::PurgeAddressesTest < ActiveSupport::TestCase
  include OrdersTestHelper

  NOON = Time.utc(2026, 11, 10, 12)

  setup do
    setup_orders_world(coins: 1000)
    travel_to NOON
  end

  teardown do
    teardown_orders_world
    travel_back
  end

  def with_address(**options) = order_for(address: true, **options)

  def address_of(order) = OrderAddress.find_by(order_id: order.id)

  def purge_events(order) = order.events.where(action: "address_purged")

  test "shipping sets the date 30 days out; nothing is deleted before it, everything on it" do
    order = with_address
    staff_do("Ship", order)
    assert_equal NOON + 30.days, address_of(order).purge_after
    assert_equal 30, Orders::Config.current.address_retention_days

    assert_equal 0, Orders::PurgeAddresses.call(now: NOON + 30.days - 1.second)
    assert_not_nil address_of(order)
    assert_equal 1, Orders::PurgeAddresses.call(now: NOON + 30.days)
    assert_nil address_of(order)
    assert_equal 1, purge_events(order).count
  end

  test "fulfilling straight from requested starts the same clock" do
    order = with_address
    staff_do("Fulfil", order)
    assert_equal NOON + 30.days, address_of(order).purge_after
  end

  test "shipped then fulfilled: the earlier moment wins" do
    order = with_address
    staff_do("Ship", order)
    travel_to NOON + 5.days
    staff_do("Fulfil", order)
    assert_equal NOON + 30.days, address_of(order).purge_after
  end

  test "the retention period comes from config" do
    with_orders_config(address_retention_days: 7) do
      order = with_address
      staff_do("Ship", order)
      assert_equal NOON + 7.days, address_of(order).purge_after
    end
  end

  test "holding, releasing and an order waiting keep the address and set no date" do
    order = with_address
    staff_do("Hold", order)
    staff_do("Release", order)
    assert_not_nil address_of(order)
    assert_nil address_of(order).purge_after
    assert_equal 0, Orders::PurgeAddresses.call(now: NOON + 400.days)
    assert_not_nil address_of(order), "an order still waiting is never purged by the date sweep"
  end

  test "every route that cancels or refunds deletes the address at once, with one history entry and no content" do
    routes = {
      "buyer cancel" => ->(o) { Orders::Cancel.call(order: o, by: @buyer, as: :buyer) },
      "staff cancel" => ->(o) { staff_do("Cancel", o, reason_code: "other") },
      "staff cancel from hold" => ->(o) { staff_do("Hold", o).then { staff_do("Cancel", Order.find(o.id), reason_code: "other") } },
      "the old Shop::Cancel door" => ->(o) { Shop::Cancel.call(order: o, by: @buyer) },
      "refund after shipping" => ->(o) { staff_do("Ship", o).then { staff_do("Refund", Order.find(o.id), reason_code: "other") } },
      "refund after fulfilling" => ->(o) { staff_do("Fulfil", o).then { staff_do("Refund", Order.find(o.id), reason_code: "other") } }
    }
    routes.each do |name, move|
      order = with_address
      assert_not_nil address_of(order)
      move.call(order)
      assert_nil address_of(order), "#{name} leaves no address"
      events = purge_events(order).to_a
      assert_equal 1, events.size, name
      assert_equal [ "system", nil, nil, nil ], [ events.first.actor_kind, events.first.actor_id, events.first.note, events.first.reason_code ]
    end
  end

  test "a staff cancel also writes the audit row, without the address" do
    order = with_address
    staff_do("Cancel", order, reason_code: "other")
    audit = AdminAuditEvent.find_by!(action: "order_address_purged", subject_id: order.id)
    assert_equal({ "order_id" => order.id }, audit.metadata)
    assert_equal @staff.id, audit.actor_id
  end

  test "a buyer's own cancel writes no staff audit row" do
    order = with_address
    Orders::Cancel.call(order: order, by: @buyer, as: :buyer)
    assert_equal 0, AdminAuditEvent.where(action: "order_address_purged").count
  end

  test "cancelling an order that never had an address changes nothing about addresses" do
    order = order_for
    staff_do("Cancel", order, reason_code: "other")
    assert_equal 0, purge_events(order).count
  end

  test "running the purge twice (or at the same time as itself) deletes and records once" do
    order = with_address
    staff_do("Ship", order)
    first = Orders::PurgeAddresses.call(now: NOON + 31.days)
    second = Orders::PurgeAddresses.call(now: NOON + 31.days)
    assert_equal [ 1, 0 ], [ first, second ]
    assert_equal 1, purge_events(order).count

    gone = OrderAddress.new(id: 0)
    assert_equal false, Orders::PurgeAddresses.delete!(gone, order), "deleting a row that is already gone is a quiet no"
    assert_equal 1, purge_events(order).count
  end

  test "a row due for deletion whose order was cancelled by hand is still caught by the sweep" do
    order = with_address
    order.update_columns(status: "cancelled", cancelled_at: Time.current)
    assert_equal 1, Orders::PurgeAddresses.call
    assert_nil address_of(order)
  end

  test "the sweep after a status change deletes anything else that is due, and never breaks the change" do
    old = with_address
    staff_do("Ship", old)
    travel_to NOON + 31.days
    other = with_address
    staff_do("Hold", other)
    assert_nil address_of(old), "a later status change tidied up the overdue one"
    assert_not_nil address_of(other)
  end

  test "a failing sweep is swallowed and logged without personal data" do
    original = Orders::PurgeAddresses.method(:call)
    Orders::PurgeAddresses.define_singleton_method(:call) { |**| raise "disk on fire" }
    begin
      assert_equal 0, Orders::PurgeAddresses.sweep_quietly
    ensure
      Orders::PurgeAddresses.define_singleton_method(:call, original)
    end
  end

  test "the batch purge works through every due row" do
    orders = Array.new(3) { with_address.tap { |o| staff_do("Ship", o) } }
    assert_equal 3, Orders::PurgeAddresses.all(now: NOON + 31.days)
    assert orders.all? { |o| address_of(o).nil? }
  end

  test "deleting the person deletes their addresses and their offers" do
    order = with_address
    offer_addresses!(@buyer, "draft-x")
    User.where(id: @buyer.id).delete_all
    assert_equal 0, OrderAddress.where(order_id: order.id).count
    assert_equal 0, AddressOffer.where(draft_key: "draft-x").count
  end

  # --- the rake tasks ---

  def run_task(name)
    Rake::Task.clear
    Rails.application.load_tasks
    out = StringIO.new
    original = $stdout
    $stdout = out
    Rake::Task[name].reenable
    Rake::Task[name].invoke
    out.string
  ensure
    $stdout = original
  end

  test "orders:purge_addresses prints counts only, is idempotent, and deletes what is due" do
    order = with_address
    staff_do("Ship", order)
    travel_to NOON + 31.days do
      assert_equal "orders:purge_addresses deleted=1\n", run_task("orders:purge_addresses")
      assert_equal "orders:purge_addresses deleted=0\n", run_task("orders:purge_addresses")
    end
    assert_nil address_of(order)
  end

  test "orders:purge_address_offers deletes expired and used offers" do
    offer_addresses!(@buyer, "draft-y")
    travel_to NOON + 20.minutes do
      assert_equal "orders:purge_address_offers deleted=1\n", run_task("orders:purge_address_offers")
    end
    assert_equal 0, AddressOffer.count
  end
end
