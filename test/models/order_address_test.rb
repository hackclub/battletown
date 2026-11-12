require "test_helper"
require_relative "../support/orders_helper"

# OrderAddress: encrypted at rest, validated, one per order, and deleted with the order or the person. Example data only.
class OrderAddressTest < ActiveSupport::TestCase
  include OrdersTestHelper

  setup do
    setup_orders_world
    @order = order_for
  end

  teardown { teardown_orders_world }

  def raw(order = @order) = ActiveRecord::Base.connection.select_one("SELECT * FROM order_addresses WHERE order_id = #{order.id}")

  test "every personal column is ciphertext in the table, for every encrypted field, and reads back" do
    give_address!(@order)
    OrderAddress::ENCRYPTED.each do |field|
      plain = ShopTestHelper::FAKE_ADDRESS.fetch(field)
      assert_not_equal plain, raw[field.to_s], "#{field} is stored as ciphertext"
      assert_not_includes raw[field.to_s], plain, "#{field} does not contain the plain text"
      assert_equal plain, @order.reload.address.public_send(field)
    end
    assert_equal "US", raw["country"], "the country is the only plain-text part"
    assert_equal OrderAddress::ENCRYPTED.sort, (OrderAddress.column_names - %w[id order_id user_id country hca_address_id purge_after created_at updated_at]).map(&:to_sym).sort
  end

  test "the same address encrypts differently each time (not deterministic)" do
    give_address!(@order)
    second = order_for
    give_address!(second)
    assert_not_equal raw(@order)["line_1"], raw(second)["line_1"]
  end

  test "inspect and logs of the record do not show the address" do
    address = give_address!(@order)
    assert_not_includes address.inspect, "Example Street"
    assert_not_includes address.inspect, "+15555550123"
    assert_includes OrderAddress.filter_attributes.map(&:to_s), "line_1" if OrderAddress.filter_attributes.any?
  end

  test "an address needs a name, a street, a city and a real country; the rest may be blank" do
    assert_predicate OrderAddress.new(order: @order, user: @buyer, recipient_name: "A", line_1: "1 Example Street", city: "Exampleville", country: "FR"), :valid?
    %i[recipient_name line_1 city].each do |field|
      assert_not OrderAddress.new(ShopTestHelper::FAKE_ADDRESS.merge(order: @order, user: @buyer, field => "")).valid?, "#{field} is required"
    end
    %w[usa U us XX 1 ZZ].each { |country| assert_not OrderAddress.new(ShopTestHelper::FAKE_ADDRESS.merge(order: @order, user: @buyer, country: country)).valid?, country }
    blank = ShopTestHelper::FAKE_ADDRESS.merge(order: @order, user: @buyer, line_2: nil, state: nil, postal_code: nil, phone_number: nil)
    assert_predicate OrderAddress.new(blank), :valid?, "no postcode, region or second line is required (many countries have none)"
  end

  test "non-Latin text round-trips" do
    address = give_address!(@order, recipient_name: "山田 太郎", line_1: "東京都港区 1-2-3", city: "東京", state: "東京都", postal_code: "100-0001", country: "JP")
    assert_equal [ "山田 太郎", "東京都港区 1-2-3", "東京" ], @order.reload.address.then { |a| [ a.recipient_name, a.line_1, a.city ] }
    assert_equal "JP", address.country
  end

  test "length caps are enforced" do
    assert_not OrderAddress.new(ShopTestHelper::FAKE_ADDRESS.merge(order: @order, user: @buyer, line_1: "x" * 201)).valid?
    assert_not OrderAddress.new(ShopTestHelper::FAKE_ADDRESS.merge(order: @order, user: @buyer, postal_code: "9" * 31)).valid?
  end

  test "the address belongs to the order's owner" do
    assert_not OrderAddress.new(ShopTestHelper::FAKE_ADDRESS.merge(order: @order, user: @other)).valid?
  end

  test "an order has at most one address (a unique key backs the model)" do
    give_address!(@order)
    assert_raises(ActiveRecord::RecordNotUnique) { OrderAddress.new(ShopTestHelper::FAKE_ADDRESS.merge(order: @order, user: @buyer)).save!(validate: false) }
  end

  test "the database refuses a country that is not two capital letters" do
    give_address!(@order)
    assert_raises(ActiveRecord::StatementInvalid) { OrderAddress.where(order_id: @order.id).update_all(country: "usa") }
  end

  test "deleting the order deletes its address; deleting the person deletes the address too" do
    give_address!(@order)
    kept = order_for
    give_address!(kept)
    assert_difference -> { OrderAddress.count }, -1 do
      Order.where(id: @order.id).delete_all
    end
    assert_difference -> { OrderAddress.count }, -1 do
      User.where(id: @buyer.id).delete_all
    end
    assert_equal 0, OrderAddress.where(user_id: @buyer.id).count
  end

  test "lines, masked lines and the masked phone" do
    address = give_address!(@order)
    assert_equal [ "Pat Example", "1 Example Street", "Flat 2", "Exampleville, EX, 00000", "US" ], address.lines
    assert_equal [ "1 Example Street", "Exampleville", "US" ], address.masked_lines
    assert_equal "Exampleville, US", address.city_and_country
    assert_equal "ends in 0123", address.masked_phone
    assert_nil give_address!(order_for, phone_number: "12").masked_phone
  end
end
