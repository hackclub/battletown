require "test_helper"
require_relative "../../support/orders_helper"

# Real threads on real connections: two clicks on "Place order" for the same checkout, and the buyer changing the address while
# staff cancel. Each test deletes its own users (and their rows, by cascade) at the end.
class Orders::AddressConcurrencyTest < ActiveSupport::TestCase
  include OrdersTestHelper

  self.use_transactional_tests = false

  setup do
    setup_orders_world(coins: 500)
    @draft = SecureRandom.hex(16)
    @ids = offer_addresses!(@buyer, @draft)
  end

  teardown do
    teardown_orders_world
    User.where(id: [ @buyer.id, @staff.id, @other.id ]).delete_all
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

  test "two threads placing the same draft make one order, one debit and one address" do
    place = -> { Orders::Place.call(user: User.find(@buyer.id), prize_key: "tshirt", idempotency_key: @draft, address_id: "addr_two", address_required: true) }
    outcomes = race(place, place, place)

    assert_equal %i[ok ok ok], outcomes.map(&:first), outcomes.inspect
    assert_equal 1, outcomes.map { |_, order| order.id }.uniq.size
    assert_equal 1, Order.where(user_id: @buyer.id).count
    assert_equal 1, OrderAddress.where(user_id: @buyer.id).count
    assert_equal 1, CoinTransaction.where(user_id: @buyer.id, kind: "purchase").count
    assert_equal 450, Coins::Balance.total(User.find(@buyer.id))
    assert_equal "addr_two", OrderAddress.find_by!(user_id: @buyer.id).hca_address_id
  end

  test "two threads claiming the sticker make one order with one address" do
    offer_addresses!(@buyer, "sticker", [ hca_address("addr_stick") ])
    claim = -> { Shop::ClaimSticker.call(user: User.find(@buyer.id), address_id: "addr_stick", address_required: true) }
    outcomes = race(claim, claim)

    assert_equal 1, outcomes.count { |kind, _| kind == :ok }
    assert_equal 1, outcomes.count { |kind, error| kind == :error && error.is_a?(Shop::AlreadyClaimed) }
    assert_equal 1, Order.where(user_id: @buyer.id, kind: "signup_sticker").count
    assert_equal 1, OrderAddress.where(user_id: @buyer.id).count
  end

  test "the buyer changing the address while staff cancel ends consistently: cancelled means no address, otherwise the new one" do
    order = buy(@buyer, "tshirt", address: true)
    offer_addresses!(@buyer, "order-#{order.id}", [ hca_address("addr_new") ])
    change = -> { Orders::AttachAddress.replace!(order: Order.find(order.id), by: User.find(@buyer.id), address_id: "addr_new") }
    cancel = -> { Orders::Cancel.call(order: Order.find(order.id), by: User.find(@staff.id), as: :staff, reason_code: "other") }
    race(change, cancel)

    fresh = Order.find(order.id)
    assert_predicate fresh, :cancelled?
    assert_nil OrderAddress.find_by(order_id: order.id), "a cancelled order keeps no address, whichever came first"
  end
end
