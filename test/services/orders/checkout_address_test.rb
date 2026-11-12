require "test_helper"
require_relative "../../support/orders_helper"

# Placing an order together with its shipping address (Orders::Place + Orders::AttachAddress, and the free sticker): the address is
# copied from the person's own unexpired offer in the same transaction as the order, or nothing is made at all.
class Orders::CheckoutAddressTest < ActiveSupport::TestCase
  include OrdersTestHelper

  setup do
    setup_orders_world(coins: 500)
    @draft = SecureRandom.hex(16)
    @ids = offer_addresses!(@buyer, @draft, [ hca_address("addr_one", primary: true), hca_address("addr_two", line_2: "Unit 9", country: "CA", state: "ON") ])
  end

  teardown { teardown_orders_world }

  def place(address_id: @ids.last, key: @draft, user: @buyer, prize: "tshirt", required: true)
    Orders::Place.call(user: user, prize_key: prize, idempotency_key: key, address_id: address_id, address_required: required)
  end

  test "the chosen address is copied into the order in the same transaction, and the offer is used up" do
    order = place
    address = order.reload.address
    assert_equal [ "Pat Example", "Two Example Street", "Unit 9", "Exampleville", "ON", "00000", "+15555550123", "CA", "addr_two" ],
                 address.attributes.values_at("recipient_name", "line_1", "line_2", "city", "state", "postal_code", "phone_number", "country", "hca_address_id")
    assert_equal @buyer.id, address.user_id
    assert_nil address.purge_after
    offer = AddressOffer.find_by!(user: @buyer, draft_key: @draft)
    assert_not_nil offer.used_at
    assert_empty offer.addresses, "the list is emptied as soon as it is used"
    assert_nil AddressOffer.live_for(@buyer, @draft)
    assert_equal 450, Coins::Balance.total(@buyer)
  end

  test "a missing address id makes no order, takes no coins and leaves the offer alone" do
    assert_raises(Orders::AddressRequired) { place(address_id: "") }
    assert_raises(Orders::AddressRequired) { place(address_id: nil) }
    assert_equal 0, Order.count
    assert_equal 0, OrderAddress.count
    assert_equal 500, Coins::Balance.total(@buyer)
    assert_not_nil AddressOffer.live_for(@buyer, @draft)
  end

  test "an id that is not in the person's own offer (tampered, stale or someone else's) makes nothing" do
    other_draft = SecureRandom.hex(16)
    offer_addresses!(@other, other_draft, [ hca_address("addr_theirs") ])
    [ "addr_nope", "addr_theirs", "ADDR_ONE", "addr_one ", [ "addr_one" ], { a: 1 } ].each do |bad|
      assert_raises(Orders::AddressNotOffered, "#{bad.inspect} should be refused") { place(address_id: bad) }
    end
    assert_raises(Orders::AddressError) { place(address_id: "addr_theirs", key: other_draft) } # not their draft either
    assert_equal 0, Order.count
    assert_equal 500, Coins::Balance.total(@buyer)
  end

  test "an offer for a different checkout cannot be used" do
    assert_raises(Orders::AddressOfferExpired) { place(key: SecureRandom.hex(16)) }
    assert_equal 0, Order.count
  end

  test "an expired offer asks to load the addresses again and makes nothing" do
    travel 16.minutes do
      assert_raises(Orders::AddressOfferExpired) { place }
    end
    assert_equal 0, Order.count
    assert_equal 0, OrderAddress.count
    assert_equal 500, Coins::Balance.total(@buyer)
  end

  test "the order and its address are made together or not at all: a failure after the address is saved rolls back the order, the debit and the address" do
    original = AddressOffer.instance_method(:use!)
    AddressOffer.define_method(:use!) { |*| raise "boom after the address was saved" }
    begin
      assert_raises(RuntimeError) { place }
    ensure
      AddressOffer.define_method(:use!, original)
    end
    assert_equal 0, Order.count
    assert_equal 0, OrderAddress.count
    assert_equal 0, CoinTransaction.where(user_id: @buyer.id, kind: "purchase").count
    assert_equal 500, Coins::Balance.total(@buyer)
    assert_not_nil AddressOffer.live_for(@buyer, @draft), "a rolled-back order does not use the offer up"
  end

  test "pressing the button twice makes one order, one debit and one address, and the repeat never reads the address again" do
    first = place
    again = place(address_id: "addr_one") # even a different id on the repeat changes nothing
    assert_equal first.id, again.id
    assert_equal 1, Order.count
    assert_equal 1, OrderAddress.count
    assert_equal "addr_two", first.reload.address.hca_address_id
    assert_equal 450, Coins::Balance.total(@buyer)
  end

  test "an order that exists is returned even after its offer has expired" do
    first = place
    travel 20.minutes do
      assert_equal first.id, place.id
    end
  end

  test "an item that is not posted needs no address" do
    ShopItem.find_by!(key: "keychain").update!(requires_shipping: false)
    order = place(prize: "keychain", key: SecureRandom.hex(16), address_id: nil, required: false)
    assert_nil order.reload.address
    assert_equal 0, OrderAddress.count
    assert_not order.address_needed?
  end

  test "the free sticker is claimed together with its address, with the draft key sticker" do
    offer_addresses!(@buyer, "sticker", [ hca_address("addr_stick") ])
    order = Shop::ClaimSticker.call(user: @buyer, address_id: "addr_stick", address_required: true)
    assert_equal "addr_stick", order.reload.address.hca_address_id
    assert_empty AddressOffer.find_by!(user: @buyer, draft_key: "sticker").addresses
  end

  test "the free sticker without an address is not claimed, and the one-per-person rule still holds" do
    assert_raises(Orders::AddressRequired) { Shop::ClaimSticker.call(user: @buyer, address_required: true) }
    assert_equal 0, Order.count
    offer_addresses!(@buyer, "sticker", [ hca_address("addr_stick") ])
    Shop::ClaimSticker.call(user: @buyer, address_id: "addr_stick", address_required: true)
    assert_raises(Shop::AlreadyClaimed) { Shop::ClaimSticker.call(user: @buyer, address_id: "addr_stick", address_required: true) }
    assert_equal 1, OrderAddress.count
  end

  test "the stored columns are ciphertext and only the country is plain" do
    order = place
    row = ActiveRecord::Base.connection.select_one("SELECT * FROM order_addresses WHERE order_id = #{order.id}")
    { "recipient_name" => "Pat Example", "line_1" => "Two Example Street", "line_2" => "Unit 9", "city" => "Exampleville", "state" => "ON",
      "postal_code" => "00000", "phone_number" => "+15555550123" }.each do |column, plain|
      assert_not_equal plain, row[column], "#{column} must be encrypted at rest"
      assert_not_includes row[column].to_s, plain.to_s, "#{column} must not hold the plain text"
      assert_equal plain, order.address.public_send(column), "#{column} reads back"
    end
    assert_equal "CA", row["country"], "the country is the one plain-text part"
    assert_equal "addr_two", row["hca_address_id"]
  end
end
