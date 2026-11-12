require "test_helper"

class ShopItems::ReorderTest < ActiveSupport::TestCase
  def keys(scope = ShopItem.active) = scope.in_order.pluck(:key)

  test "moving an item up swaps it with the one above and renumbers 1..n" do
    before = keys
    assert ShopItems::Reorder.call(key: before[3], direction: "up")
    expected = before.dup
    expected[2], expected[3] = expected[3], expected[2]
    assert_equal expected, keys
    assert_equal (1..expected.size).to_a, ShopItem.active.in_order.pluck(:position)
  end

  test "moving an item down swaps it with the one below" do
    before = keys
    assert ShopItems::Reorder.call(key: before[0], direction: "down")
    assert_equal [ before[1], before[0] ], keys.first(2)
  end

  test "the top cannot go up and the bottom cannot go down" do
    before = keys
    assert_not ShopItems::Reorder.call(key: before.first, direction: "up")
    assert_not ShopItems::Reorder.call(key: before.last, direction: "down")
    assert_equal before, keys
  end

  test "ties and gaps are cleaned up by a move" do
    ShopItem.update_all(position: 5)
    before = ShopItem.active.order(:id).pluck(:key)
    ShopItems::Reorder.call(key: before[1], direction: "up")
    assert_equal (1..before.size).to_a, ShopItem.active.in_order.pluck(:position)
    assert_equal before[1], keys.first
  end

  test "active and archived items are separate lists, so moving one never disturbs the other" do
    ShopItem.where(key: %w[poster keychain]).update_all(active: false)
    active_before = keys
    archived_before = keys(ShopItem.archived)
    ShopItems::Reorder.call(key: archived_before.last, direction: "up")
    assert_equal active_before, keys
    assert_equal archived_before.reverse, keys(ShopItem.archived)
  end

  test "it bumps lock_version only on items it moved, so an open edit form goes stale" do
    before = ShopItem.active.in_order.map { |item| [ item.key, item.lock_version ] }.to_h
    keys_in_order = before.keys
    ShopItems::Reorder.call(key: keys_in_order[1], direction: "up")
    after = ShopItem.active.in_order.map { |item| [ item.key, item.lock_version ] }.to_h
    assert_operator after[keys_in_order[0]], :>, before[keys_in_order[0]]
    assert_operator after[keys_in_order[1]], :>, before[keys_in_order[1]]
    assert_equal before[keys_in_order[2]], after[keys_in_order[2]]
  end

  test "the facade sees the new order straight away" do
    first = Prize.paid.first.key
    ShopItems::Reorder.call(key: first, direction: "down")
    assert_equal first, Prize.paid[1].key
  end

  test "a bad direction or an unknown key is an error, not a silent move" do
    assert_raises(ArgumentError) { ShopItems::Reorder.call(key: "tshirt", direction: "sideways") }
    assert_raises(ActiveRecord::RecordNotFound) { ShopItems::Reorder.call(key: "nope", direction: "up") }
  end
end
