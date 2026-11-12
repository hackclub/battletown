# The shop grid and the confirmation page for one item. Spending is locked until identity is verified with Hack Club
# (Shop::Spendable); the free signup sticker is separate (StickerClaimsController). Nothing here blocks coding.
class ShopController < ApplicationController
  before_action :require_login, :require_onboarded

  def index
    @prizes = Prize.paid.sort_by { |prize| [ prize.coins, prize.name ] }
    @total = Coins::Balance.total(current_user)
    @spendable = Shop::Spendable.balance(current_user)
    @locked = Shop::Spendable.locked?(current_user)
    @sticker = Prize.free_signup
    @sticker_order = current_user.orders.find_by(kind: "signup_sticker")
  end

  # "Get this": shows the price and the balance afterwards. The idempotency key is made here, once per page view, and
  # travels in a hidden field, so pressing the button twice (or reloading the POST) can only ever make one order.
  def show
    @prize = Prize.paid.find { |prize| prize.key == params[:key] } or raise ActionController::RoutingError, "Not Found"
    @spendable = Shop::Spendable.balance(current_user)
    return redirect_to(shop_path, alert: Shop::NotVerified.new.message) if Shop::Spendable.locked?(current_user)
    return redirect_to(shop_path, alert: Shop::InsufficientCoins.new.message) if @spendable < @prize.coins

    @balance_after = @spendable - @prize.coins
    @idempotency_key = SecureRandom.hex(16)
  end
end
