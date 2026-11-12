# Development-only: give the signed-in user 100 test coins (a ledger `adjustment`) so the shop can be tried before any
# ship has been approved. Outside development every request is a 404 (same as an unknown path).
module Dev
  class CoinsController < ApplicationController
    TEST_COINS = 100

    before_action :require_development!
    before_action :require_login

    def create
      Coins::Ledger.credit(user: current_user, amount: TEST_COINS, kind: "adjustment", note: "Dev shop test coins",
                           created_by: "dev:shop", idempotency_key: "dev:shop:#{SecureRandom.hex(8)}")
      redirect_to shop_path, notice: "Added #{TEST_COINS} test coins."
    end

    private

    def require_development!
      raise ActionController::RoutingError, "Not Found" unless Rails.env.development?
    end
  end
end
