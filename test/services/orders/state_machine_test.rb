require "test_helper"

# The lifecycle table, checked cell by cell: every status x action x actor, legal and illegal.
class Orders::StateMachineTest < ActiveSupport::TestCase
  Machine = Orders::StateMachine

  # [action, from, actor] => the status it leads to. Everything not listed here must be refused.
  LEGAL = {
    [ "hold", "requested", "staff" ] => "on_hold",
    [ "release", "on_hold", "staff" ] => "requested",
    [ "ship", "requested", "staff" ] => "shipped",
    [ "fulfil", "requested", "staff" ] => "fulfilled",
    [ "fulfil", "shipped", "staff" ] => "fulfilled",
    [ "cancel", "requested", "buyer" ] => "cancelled",
    [ "cancel", "requested", "staff" ] => "cancelled",
    [ "cancel", "on_hold", "staff" ] => "cancelled",
    [ "refund", "shipped", "staff" ] => "refunded",
    [ "refund", "fulfilled", "staff" ] => "refunded"
  }.freeze

  test "the table has exactly the six statuses and six actions of the contract" do
    assert_equal %w[requested on_hold shipped fulfilled cancelled refunded], Order::STATUSES
    assert_equal %w[hold release ship fulfil cancel refund], Machine::ACTIONS
    assert_equal %w[buyer staff], Machine::ACTORS
    assert_equal Machine::ACTIONS.sort, Machine::TARGETS.keys.sort
  end

  test "every status x action x actor is allowed exactly when the table says so" do
    count = 0
    Order::STATUSES.product(Machine::ACTIONS, Machine::ACTORS).each do |status, action, actor|
      expected = LEGAL.key?([ action, status, actor ])
      assert_equal expected, Machine.allowed?(action, status, actor), "#{actor} #{action} from #{status}"
      count += 1
    end
    assert_equal 6 * 6 * 2, count
  end

  test "every legal move leads to the status the table names, and TARGETS agrees" do
    LEGAL.each do |(action, _from, _actor), to|
      assert_equal to, Machine.target(action)
    end
  end

  test "the buyer can only cancel, and only while requested" do
    Order::STATUSES.each do |status|
      expected = status == "requested" ? [ "cancel" ] : []
      assert_equal expected, Machine.actions_for(status, "buyer"), status
    end
  end

  test "what staff can do from each status" do
    assert_equal %w[hold ship fulfil cancel], Machine.actions_for("requested", "staff")
    assert_equal %w[release cancel], Machine.actions_for("on_hold", "staff")
    assert_equal %w[fulfil refund], Machine.actions_for("shipped", "staff")
    assert_equal %w[refund], Machine.actions_for("fulfilled", "staff")
    assert_empty Machine.actions_for("cancelled", "staff")
    assert_empty Machine.actions_for("refunded", "staff")
  end

  test "a held order cannot be shipped or fulfilled until it is released" do
    assert_not Machine.allowed?("ship", "on_hold", "staff")
    assert_not Machine.allowed?("fulfil", "on_hold", "staff")
  end

  test "cancelled and refunded are final, nothing leaves them" do
    %w[cancelled refunded].each do |status|
      assert Machine.final?(status)
      Machine::ACTIONS.product(Machine::ACTORS).each { |action, actor| assert_not Machine.allowed?(action, status, actor), "#{actor} #{action} from #{status}" }
    end
    %w[requested on_hold shipped fulfilled].each { |status| assert_not Machine.final?(status), status }
  end

  test "an action that lands where the order already is counts as already done" do
    Machine::TARGETS.each { |action, status| assert Machine.already?(action, status), action }
    assert_not Machine.already?("cancel", "requested")
    assert_not Machine.already?("ship", "on_hold")
  end

  test "only cancel and refund give coins back, and staff must give a reason for both" do
    assert_equal %w[cancel refund], Machine::ACTIONS.select { |action| Machine.refunds?(action) }
    Machine::ACTIONS.each do |action|
      assert_equal %w[cancel refund].include?(action), Machine.reason_required?(action, "staff"), action
      assert_not Machine.reason_required?(action, "buyer"), "the buyer never needs a reason (#{action})"
    end
  end

  test "an action that no actor may ever do is refused before anything else" do
    assert Machine.actor_may?("cancel", "buyer")
    %w[hold release ship fulfil refund].each { |action| assert_not Machine.actor_may?(action, "buyer"), action }
    assert_not Machine.actor_may?("hold", "stranger")
    assert_not Machine.allowed?("bogus", "requested", "staff")
  end

  test "event names match the history table's allowed actions" do
    assert_empty Machine::EVENT_ACTIONS.values - OrderEvent::ACTIONS
  end

  test "the table is pure data: it does not touch the database" do
    queries = 0
    callback = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Order::STATUSES.product(Machine::ACTIONS, Machine::ACTORS).each { |status, action, actor| Machine.allowed?(action, status, actor) }
    end
    assert_equal 0, queries
  end
end
