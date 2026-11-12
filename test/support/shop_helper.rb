require "test_helper"
require_relative "coins_helper"

# Helpers for the shop tests.
module ShopTestHelper
  include CoinsHelper

  def verified!(user)
    user.update_columns(verification_status: "verified")
    user
  end

  def give_coins(user, amount, key: "seed-#{SecureRandom.hex(4)}")
    Coins::Ledger.credit(user: user, amount: amount, kind: "adjustment", idempotency_key: key)
  end

  def buy(user, prize_key = "tshirt", key: SecureRandom.hex(8))
    Shop::Purchase.call(user: user, prize_key: prize_key, idempotency_key: key)
  end

  def admin_user
    users(:new_user).tap { |user| user.update_columns(hca_uid: "ident!shop-admin") }
  end
end
