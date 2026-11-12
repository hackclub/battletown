require "test_helper"
require_relative "../../support/orders_helper"

# The six transition services (Orders::Hold, Release, Ship, Fulfil, Cancel, Refund), the note and tracking edits, and the order
# page placing cap (Orders::Place): what each does, who may, what it writes (history, audit, ledger) and what a repeat does.
class Orders::TransitionsTest < ActiveSupport::TestCase
  include OrdersTestHelper

  setup { setup_orders_world }
  teardown { teardown_orders_world }

  SERVICES = { "hold" => "Hold", "release" => "Release", "ship" => "Ship", "fulfil" => "Fulfil", "cancel" => "Cancel", "refund" => "Refund" }.freeze

  # --- the table, played against the real services ---

  test "every status x action x actor either does exactly what the table says or is refused and changes nothing" do
    give_coins(@buyer, 10_000)
    Order::STATUSES.each do |status|
      Orders::StateMachine::ACTIONS.each do |action|
        Orders::StateMachine::ACTORS.each do |actor|
          order = order_in(status)
          legal = Orders::StateMachine.allowed?(action, status, actor)
          already = Orders::StateMachine.already?(action, status)
          before = [ order.status, OrderEvent.where(order: order).count, refunds_for.count ]
          who = actor == "staff" ? @staff : @buyer
          options = { order: order, by: who, as: actor.to_sym }
          options[:reason_code] = "other" if actor == "staff" && %w[cancel refund].include?(action)
          call = -> { "Orders::#{SERVICES.fetch(action)}".constantize.call(**options) }
          label = "#{actor} #{action} from #{status}"

          if legal
            result = call.call
            assert_predicate result, :changed?, label
            assert_equal Orders::StateMachine.target(action), order.reload.status, label
            assert_equal before[1] + 1, OrderEvent.where(order: order).count, label
          elsif already && Orders::StateMachine.actor_may?(action, actor)
            result = call.call
            assert_predicate result, :unchanged?, label
            assert_equal before, [ order.reload.status, OrderEvent.where(order: order).count, refunds_for.count ], label
          else
            assert_raises(Orders::NotAllowed, label) { call.call }
            assert_equal before, [ order.reload.status, OrderEvent.where(order: order).count, refunds_for.count ], label
          end
        end
      end
    end
  end

  # --- history, audit ---

  test "every move writes one history row with the right actor kind, statuses and reason, and one staff audit row" do
    order = order_for
    staff_do("Hold", order, note: "Waiting on stock")
    staff_do("Release", order)
    staff_do("Ship", order, tracking: { carrier: "usps", number: "9400 1000 0000 0000 0000 00" })
    staff_do("Fulfil", order)
    staff_do("Refund", order, reason_code: "out_of_stock", note: "Lost in the post")

    events = order.events.order(:id).to_a
    assert_equal %w[held released shipped fulfilled refunded], events.map(&:action)
    assert_equal %w[requested on_hold requested shipped fulfilled], events.map(&:from_status)
    assert_equal %w[on_hold requested shipped fulfilled refunded], events.map(&:to_status)
    assert events.all? { |event| event.actor_kind == "staff" && event.actor_id == @staff.id }
    assert_equal [ "Waiting on stock", nil, nil, nil, "Lost in the post" ], events.map(&:note)
    assert_equal [ nil, nil, nil, nil, "out_of_stock" ], events.map(&:reason_code)

    audit = AdminAuditEvent.where(subject_type: "Order", subject_id: order.id).order(:id)
    assert_equal %w[order_held order_released order_shipped order_fulfilled order_refunded], audit.map(&:action)
    assert audit.all? { |row| row.actor_id == @staff.id }
    assert_equal({ "order_id" => order.id, "from_status" => "fulfilled", "to_status" => "refunded", "reason_code" => "out_of_stock", "coins" => 50 }, audit.last.metadata)
    assert_not_includes audit.map { |row| row.metadata.to_s }.join, "Lost in the post", "the note never reaches the audit trail"
  end

  test "the buyer's own cancel is a buyer event with no actor id, no reason and no audit row" do
    order = order_for
    Orders::Cancel.call(order: order, by: @buyer, as: :buyer, reason_code: "fraud_abuse", note: "ignored")
    event = order.events.last
    assert_equal [ "buyer", nil, nil, nil, "cancelled" ], [ event.actor_kind, event.actor_id, event.reason_code, event.note, event.action ]
    assert_equal 0, AdminAuditEvent.where(subject_type: "Order").count
  end

  test "history rows are append-only" do
    event = order_for.tap { |order| staff_do("Hold", order) }.events.last
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(note: "edited") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update_columns(note: "edited") }
  end

  # --- idempotency and the one refund ---

  test "repeating a move changes nothing: no second event, no second audit row, no second refund" do
    order = order_for
    first = staff_do("Cancel", order, reason_code: "duplicate")
    again = staff_do("Cancel", Order.find(order.id), reason_code: "duplicate")
    assert_predicate first, :changed?
    assert_predicate again, :unchanged?
    assert_nil again.event
    assert_equal 1, order.events.count
    assert_equal 1, AdminAuditEvent.where(action: "order_cancelled").count
    assert_equal 1, refunds_for.count
    assert_equal 500, Coins::Balance.total(@buyer)
  end

  test "the buyer cancelling after staff already cancelled changes nothing" do
    order = order_for
    staff_do("Cancel", order, reason_code: "buyer_request")
    result = Orders::Cancel.call(order: Order.find(order.id), by: @buyer, as: :buyer)
    assert_predicate result, :unchanged?
    assert_equal 1, refunds_for.count
  end

  test "a refund is exactly the coins on the order, even after the item's price has changed" do
    order = Order.create!(user: @buyer, prize_key: "tshirt", prize_name: "Battletown T-shirt", coins: 77, kind: "purchase", idempotency_key: "old-price")
    Coins::Ledger.debit(user: @buyer, amount: 77, kind: "purchase", reference: order, idempotency_key: "shop:purchase:old-price")
    assert_not_equal 77, Prize.find("tshirt").coins, "the catalogue price differs from the price paid"
    before = Coins::Balance.total(@buyer)

    staff_do("Ship", order)
    staff_do("Refund", order, reason_code: "other")
    assert_equal [ 77 ], refunds_for.map(&:amount)
    assert_equal before + 77, Coins::Balance.total(@buyer)
  end

  test "cancel, shipped to refunded and fulfilled to refunded each write one refund entry keyed on the order" do
    cancelled = order_in("cancelled")
    shipped_then_refunded = order_in("shipped").tap { |order| staff_do("Refund", order, reason_code: "address_problem") }
    fulfilled_then_refunded = order_in("fulfilled").tap { |order| staff_do("Refund", order, reason_code: "other") }
    [ cancelled, shipped_then_refunded, fulfilled_then_refunded ].each do |order|
      entries = CoinTransaction.where(kind: "refund", reference_type: "Order", reference_id: order.id)
      assert_equal 1, entries.count
      assert_equal "shop:refund:#{order.id}", entries.first.idempotency_key
      assert_equal order.coins, entries.first.amount
    end
  end

  test "nothing is refunded for a status that gives no coins back" do
    order = order_in("shipped")
    staff_do("Fulfil", order)
    staff_do("Hold", order_in("requested"))
    assert_equal 0, refunds_for.count
  end

  test "coins for the free sticker are zero, so cancelling or refunding it refunds nothing, and it can't be claimed again" do
    sticker = Shop::ClaimSticker.call(user: @other)
    staff_do("Ship", sticker)
    staff_do("Refund", sticker, reason_code: "other")
    assert_predicate sticker.reload, :refunded?
    assert_equal 0, refunds_for(@other).count
    assert_raises(Shop::AlreadyClaimed) { Shop::ClaimSticker.call(user: @other) }

    third = verified!(build_user)
    sticker = Shop::ClaimSticker.call(user: third)
    staff_do("Cancel", sticker, reason_code: "other")
    assert_equal 0, refunds_for(third).count
    assert_raises(Shop::AlreadyClaimed) { Shop::ClaimSticker.call(user: third) }
  end

  test "the owner can't cancel their free sticker but staff can" do
    sticker = Shop::ClaimSticker.call(user: @other)
    assert_raises(Orders::NotAllowed) { Orders::Cancel.call(order: sticker, by: @other, as: :buyer) }
    assert_predicate sticker.reload, :requested?
    staff_do("Cancel", sticker, reason_code: "other")
    assert_predicate sticker.reload, :cancelled?
  end

  # --- who ---

  test "the buyer can't do anything but cancel, and can't touch someone else's order" do
    order = order_for
    %w[Hold Release Ship Fulfil Refund].each do |service|
      assert_raises(Orders::NotAllowed, service) { "Orders::#{service}".constantize.call(order: order, by: @buyer, as: :buyer) }
    end
    assert_raises(Orders::NotAllowed) { Orders::Cancel.call(order: order, by: @other, as: :buyer) }
    assert_predicate order.reload, :requested?
  end

  test "claiming to be staff without being an admin is refused" do
    order = order_for
    assert_raises(Orders::NotAllowed) { Orders::Hold.call(order: order, by: @buyer, as: :staff) }
    assert_raises(Orders::NotAllowed) { Orders::Ship.call(order: order, by: nil, as: :staff) }
    assert_raises(Orders::NotAllowed) { Orders::Hold.call(order: order, by: @staff, as: :wizard) }
    assert_predicate order.reload, :requested?
  end

  test "an admin who bought something cancels it as a buyer, without a reason, and it is a buyer event" do
    ENV["ADMIN_HCA_UIDS"] = [ @staff.hca_uid, @buyer.hca_uid ].join(",")
    order = order_for
    Orders::Cancel.call(order: order, by: @buyer, as: :buyer)
    assert_equal "buyer", order.events.last.actor_kind
    assert_equal 0, AdminAuditEvent.where(action: "order_cancelled").count
  end

  # --- reasons and notes ---

  test "a staff cancel or refund needs a reason from the list" do
    order = order_for
    [ nil, "", "nonsense", "OTHER", "other; drop table", "buyer request" ].each do |bad|
      assert_raises(Orders::Invalid, bad.inspect) { staff_do("Cancel", order, reason_code: bad) }
    end
    assert_predicate order.reload, :requested?
    assert_equal 0, refunds_for.count
    staff_do("Ship", order)
    assert_raises(Orders::Invalid) { staff_do("Refund", order) }
    Orders::Config.current.reason_codes.each_key { |code| assert Orders::Config.current.reason_label(code) }
    assert_equal %w[out_of_stock buyer_request address_problem fraud_abuse duplicate other], Orders::Config.current.reason_codes.keys
  end

  test "a reason given on a move that doesn't need one must still be on the list" do
    order = order_for
    assert_raises(Orders::Invalid) { staff_do("Hold", order, reason_code: "nonsense") }
    staff_do("Hold", order, reason_code: "out_of_stock")
    assert_equal "out_of_stock", order.events.last.reason_code
  end

  test "notes are squished, kept to 300 characters and free of control characters" do
    order = order_for
    staff_do("Hold", order, note: "  needs\n  a   check  ")
    assert_equal "needs a check", order.events.last.note
    assert_raises(Orders::Invalid) { staff_do("Release", order, note: "x" * 301) }
    assert_raises(Orders::Invalid) { staff_do("Release", order, note: "bad\u0007bell") }
    staff_do("Release", order, note: "y" * 300)
    assert_equal 300, order.events.last.note.length
  end

  test "the note action adds a history row without changing the status, in any status, staff only" do
    Order::STATUSES.each do |status|
      order = order_in(status)
      result = Orders::AddNote.call(order: order, by: @staff, note: "Called the supplier")
      assert_predicate result, :changed?
      assert_equal status, order.reload.status
      assert_equal [ "note_added", status, status, "Called the supplier" ], order.events.last.then { |e| [ e.action, e.from_status, e.to_status, e.note ] }
    end
    order = order_for
    assert_raises(Orders::NotAllowed) { Orders::AddNote.call(order: order, by: @buyer, note: "hi") }
    assert_raises(Orders::Invalid) { Orders::AddNote.call(order: order, by: @staff, note: "   ") }
    assert_raises(Orders::Invalid) { Orders::AddNote.call(order: order, by: @staff, note: "z" * 301) }
    audit = AdminAuditEvent.where(action: "order_note_added").last
    assert_equal %w[order_id status], audit.metadata.keys.sort
    assert_not_includes audit.metadata.to_s, "supplier"
  end

  # --- shipping and tracking ---

  test "shipping with tracking stores it, sets shipped_at and writes no number into the history or the audit trail" do
    order = order_for
    staff_do("Ship", order, tracking: { carrier: "ups", number: "1Z999AA10123456784" })
    order.reload
    assert_equal [ "shipped", "ups", "1Z999AA10123456784" ], [ order.status, order.tracking_carrier, order.tracking_number ]
    assert_not_nil order.shipped_at
    everything = [ OrderEvent.where(order: order).map(&:attributes), AdminAuditEvent.where(subject_id: order.id).map(&:attributes) ].to_json
    assert_not_includes everything, "1Z999AA10123456784"
  end

  test "shipping without tracking is allowed" do
    order = order_for
    staff_do("Ship", order)
    assert_predicate order.reload, :shipped?
    assert_nil order.tracking_number
    assert_nil order.tracking_carrier
  end

  test "tracking is validated: carrier from the list, plain number, label only for other" do
    give_coins(@buyer, 2000)
    bad = [
      { carrier: "ups", number: "" },
      { carrier: "", number: "1Z999AA10123456784" },
      { carrier: "pigeon", number: "123456789" },
      { carrier: "ups", number: "12" },
      { carrier: "ups", number: "1Z999AA1<script>" },
      { carrier: "ups", number: "javascript:alert(1)" },
      { carrier: "ups", number: "../../etc/passwd" },
      { carrier: "ups", number: "A" * 61 },
      { carrier: "ups", number: "1Z999AA10123456784", label: "Mine" },
      { carrier: "other", number: "123456789", label: "L" * 41 },
      { carrier: "other", number: "123456789", label: "Bad\u0007label" }
    ]
    bad.each do |tracking|
      order = order_for
      assert_raises(Orders::Invalid, tracking.inspect) { staff_do("Ship", order, tracking: tracking) }
      assert_predicate order.reload, :requested?, "a refused tracking must not ship the order"
      assert_nil order.shipped_at
    end
    order = order_for
    staff_do("Ship", order, tracking: { carrier: "other", number: "ABC 123-456", label: "Local courier" })
    assert_equal [ "other", "ABC 123-456", "Local courier" ], [ order.reload.tracking_carrier, order.tracking_number, order.tracking_label ]
  end

  test "shipping an already shipped order changes nothing, tracking included" do
    order = order_in("shipped")
    result = staff_do("Ship", order, tracking: { carrier: "dhl", number: "JD0146000000" })
    assert_predicate result, :unchanged?
    assert_equal [ "ups", "1Z999AA10123456784" ], [ order.reload.tracking_carrier, order.tracking_number ]
  end

  test "an admin can edit the tracking after shipping, audited, with no number in the event" do
    order = order_in("shipped")
    result = Orders::UpdateTracking.call(order: order, by: @staff, tracking: { carrier: "fedex", number: "794644790138" })
    assert_predicate result, :changed?
    assert_equal [ "fedex", "794644790138" ], [ order.reload.tracking_carrier, order.tracking_number ]
    assert_equal [ "tracking_updated", "shipped", "shipped", nil ], order.events.last.then { |e| [ e.action, e.from_status, e.to_status, e.note ] }
    audit = AdminAuditEvent.where(action: "order_tracking_updated").last
    assert_equal({ "order_id" => order.id, "status" => "shipped", "tracking_carrier" => "fedex" }, audit.metadata)
    assert_predicate Orders::UpdateTracking.call(order: order, by: @staff, tracking: { carrier: "fedex", number: "794644790138" }), :unchanged?
    assert_equal 1, order.events.where(action: "tracking_updated").count
    Orders::UpdateTracking.call(order: order, by: @staff, tracking: {})
    assert_nil order.reload.tracking_number
  end

  test "tracking can't be edited by the buyer, on an unsent order, or with bad input" do
    order = order_for
    assert_raises(Orders::NotAllowed) { Orders::UpdateTracking.call(order: order, by: @staff, tracking: { carrier: "ups", number: "1Z999AA10123456784" }) }
    shipped = order_in("shipped")
    assert_raises(Orders::NotAllowed) { Orders::UpdateTracking.call(order: shipped, by: @buyer, tracking: { carrier: "ups", number: "1Z999AA10123456784" }) }
    assert_raises(Orders::Invalid) { Orders::UpdateTracking.call(order: shipped, by: @staff, tracking: { carrier: "ups", number: "bad<>" }) }
    cancelled = order_in("cancelled")
    assert_raises(Orders::NotAllowed) { Orders::UpdateTracking.call(order: cancelled, by: @staff, tracking: { carrier: "ups", number: "1Z999AA10123456784" }) }
  end

  test "a held order has to be released before it can ship, and a release sends nothing" do
    order = order_in("on_hold")
    assert_raises(Orders::NotAllowed) { staff_do("Ship", order) }
    assert_raises(Orders::NotAllowed) { staff_do("Fulfil", order) }
    staff_do("Release", order)
    assert_predicate order.reload, :requested?
    assert_empty Notification.where(user: @buyer)
  end

  test "timestamps follow the statuses (the database checks agree)" do
    shipped = order_in("shipped")
    assert_not_nil shipped.shipped_at
    assert_nil shipped.fulfilled_at
    fulfilled = order_in("fulfilled")
    assert_not_nil fulfilled.fulfilled_at
    assert_nil fulfilled.shipped_at
    staff_do("Refund", fulfilled, reason_code: "other")
    assert_not_nil fulfilled.reload.fulfilled_at, "a refunded fulfilled order keeps when it was fulfilled"
    assert_not_nil fulfilled.refunded_at
    assert_not_nil order_in("cancelled").cancelled_at
  end

  test "the old Shop::Cancel and Shop::Fulfill doorways still work and return the order" do
    cancelled = order_for
    assert_equal cancelled, Shop::Cancel.call(order: cancelled, by: @buyer)
    assert_predicate cancelled.reload, :cancelled?
    by_staff = order_for
    Shop::Cancel.call(order: by_staff, by: @staff)
    assert_equal [ "staff", "other" ], by_staff.events.last.then { |e| [ e.actor_kind, e.reason_code ] }
    fulfilled = order_for
    assert_predicate Shop::Fulfill.call(order: fulfilled, by: @staff), :fulfilled?
    assert_raises(Orders::NotAllowed) { Shop::Fulfill.call(order: order_for, by: @buyer) }
    assert_equal 2, refunds_for.count
  end

  # --- placing, the cap ---

  test "a person can have at most the configured number of orders waiting, friendly error, and a repeat of an old order still works" do
    cap = Orders::Config.current.max_open_requested
    give_coins(@buyer, 5000)
    keys = Array.new(cap) { |i| "cap-#{i}" }
    keys.each { |key| Orders::Place.call(user: @buyer, prize_key: "sticker_pack", idempotency_key: key) }
    error = assert_raises(Orders::TooManyOpen) { Orders::Place.call(user: @buyer, prize_key: "sticker_pack", idempotency_key: "cap-extra") }
    assert_match(/#{cap} orders waiting/, error.message)
    assert_kind_of Shop::Error, error
    assert_equal cap, Order.where(user: @buyer).count
    assert_nothing_raised { Orders::Place.call(user: @buyer, prize_key: "sticker_pack", idempotency_key: keys.first) }
    assert_equal cap, Order.where(user: @buyer).count

    staff_do("Ship", Order.where(user: @buyer).first)
    assert_nothing_raised { Orders::Place.call(user: @buyer, prize_key: "sticker_pack", idempotency_key: "cap-after-ship") }
  end

  test "an order on hold still counts as waiting, a cancelled one doesn't, and the sticker is separate" do
    with_orders_config(max_open_requested: 2) do
      held = Orders::Place.call(user: @buyer, prize_key: "sticker_pack", idempotency_key: "w1")
      Orders::Place.call(user: @buyer, prize_key: "sticker_pack", idempotency_key: "w2")
      staff_do("Hold", held)
      assert_raises(Orders::TooManyOpen) { Orders::Place.call(user: @buyer, prize_key: "sticker_pack", idempotency_key: "w3") }
      Orders::Cancel.call(order: Order.find_by!(user: @buyer, idempotency_key: "w2"), by: @buyer, as: :buyer)
      assert_nothing_raised { Orders::Place.call(user: @buyer, prize_key: "sticker_pack", idempotency_key: "w3") }
      assert_nothing_raised { Shop::ClaimSticker.call(user: @buyer) }
    end
  end
end
