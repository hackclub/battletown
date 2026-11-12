require "test_helper"
require_relative "coins_helper"

# Helpers for the shop tests.
module ShopTestHelper
  include CoinsHelper

  def verified!(user)
    user.update_columns(verification_status: "verified")
    user
  end

  # Verified AND eligible for Hack Club YSWS programs, with a fresh sign-in copy: can spend even with `eligibility_gate` on.
  def eligible!(user, checked_at: Time.current)
    user.update_columns(verification_status: "verified", ysws_eligible: true, verification_checked_at: checked_at)
    user
  end

  def give_coins(user, amount, key: "seed-#{SecureRandom.hex(4)}")
    Coins::Ledger.credit(user: user, amount: amount, kind: "adjustment", idempotency_key: key)
  end

  # Buys through the service. `address: true` also gives a posted item the shipping address checkout would have copied in.
  def buy(user, prize_key = "tshirt", key: SecureRandom.hex(8), address: false)
    order = Shop::Purchase.call(user: user, prize_key: prize_key, idempotency_key: key)
    give_address!(order) if address && order.requires_shipping? && !order.address
    order
  end

  FAKE_ADDRESS = { recipient_name: "Pat Example", line_1: "1 Example Street", line_2: "Flat 2", city: "Exampleville", state: "EX", postal_code: "00000",
                   country: "US", phone_number: "+15555550123", hca_address_id: "addr_test" }.freeze

  # A shipping address on the order (example data only: nothing here is a real street, name or number).
  def give_address!(order, **attributes)
    order.association(:address).reset
    OrderAddress.create!(FAKE_ADDRESS.merge(attributes).merge(order: order, user: order.user))
  end

  # A Hack Club Auth address as Hca::Me would return it.
  def hca_address(id = "addr_one", **attributes)
    street = "#{id.delete_prefix('addr_').capitalize} Example Street"
    base = { "id" => id, "recipient_name" => "Pat Example", "line_1" => street, "city" => "Exampleville", "state" => "EX", "postal_code" => "00000",
             "country" => "US", "phone_number" => "+15555550123", "primary" => false }
    Hca::Address.from_stored(base.merge(attributes.stringify_keys))
  end

  # Integration tests: posts an order the way the confirm page does for a posted item. The Hack Club Auth round trip is skipped (the
  # offer is stored directly, as the callback leaves it), then the order is posted with the id of one offered address.
  def post_order_as(user, prize_key: "tshirt", key: SecureRandom.hex(16), **extra)
    address_id = offer_addresses!(user, key).first
    post orders_path, params: { prize_key: prize_key, idempotency_key: key, address_id: address_id }.merge(extra)
  end

  # Integration tests: claims the free sticker with an offered address (draft key "sticker").
  def claim_sticker_as(user)
    post shop_sticker_path, params: { address_id: offer_addresses!(user, "sticker").first }
  end

  # Stores an address offer for a checkout draft the way the Hack Club Auth round trip does; returns the ids offered.
  def offer_addresses!(user, draft_key, addresses = [ hca_address("addr_one", primary: true), hca_address("addr_two") ])
    AddressOffer.store!(user: user, draft_key: draft_key, result: Hca::Me::Result.new(addresses: addresses, skipped: 0))
    addresses.map(&:id)
  end

  def admin_user
    users(:new_user).tap { |user| user.update_columns(hca_uid: "ident!shop-admin") }
  end
end
