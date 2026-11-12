# The shop grid and the confirmation page for one item. Spending is locked until `User#can_spend_coins?` (identity
# verified with Hack Club, plus eligibility while the `eligibility_gate` flag is on; Shop::Spendable); the free signup sticker is separate (StickerClaimsController). Nothing here blocks coding.
class ShopController < ApplicationController
  before_action :require_login, :require_onboarded

  def index
    @prizes = Prize.paid # in the order staff set at /admin/shop
    @total = Coins::Balance.total(current_user)
    @spendable = Shop::Spendable.balance(current_user)
    @spend_state = current_user.spend_state
    @locked = @spend_state != :ready
    @sticker = Prize.free_signup
    @sticker_order = current_user.orders.find_by(kind: "signup_sticker")
  end

  # "Get this": shows the price and the balance afterwards. The idempotency key is made here, once per page view, and
  # travels in a hidden field, so pressing the button twice (or reloading the POST) can only ever make one order.
  def show
    prize = Prize.find(params[:key])
    raise ActionController::RoutingError, "Not Found" if prize.nil? || prize.free_signup?
    return redirect_to(shop_path, alert: Shop::ItemUnavailable.new.message) unless prize.active?

    @prize = prize
    @spendable = Shop::Spendable.balance(current_user)
    Shop::Spendable.check!(current_user)
    return redirect_to(shop_path, alert: Shop::InsufficientCoins.new.message) if @spendable < @prize.coins

    @balance_after = @spendable - @prize.coins
    @idempotency_key = SecureRandom.hex(16)
  rescue Shop::NotVerified, Shop::NotEligible, Shop::NeedsRecheck => error
    redirect_to shop_path, alert: error.message
  end
end
