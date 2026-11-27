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
  #
  # A physical item also asks where to send it (the "address step": the person's Hack Club Auth addresses, loaded on demand and
  # chosen in a dropdown). Coming back from that round trip the same key arrives as `draft`, so the page, the address offer and the
  # order all share one key. A draft that already made an order opens that order instead (back button, refresh).
  def show
    prize = Prize.find(params[:key])
    raise ActionController::RoutingError, "Not Found" if prize.nil? || prize.free_signup?
    return redirect_to(shop_path, alert: Shop::ItemUnavailable.new.message) unless prize.active?

    @prize = prize
    @spendable = Shop::Spendable.balance(current_user)
    Shop::Spendable.check!(current_user)
    return redirect_to(shop_path, alert: Shop::InsufficientCoins.new.message) if @spendable < @prize.coins

    @balance_after = @spendable - @prize.coins
    @idempotency_key = draft_key
    existing = current_user.orders.find_by(idempotency_key: @idempotency_key)
    return redirect_to(order_path(existing)) if existing

    load_address_step(prize) if prize.requires_shipping?
  rescue Shop::NotVerified, Shop::NotEligible, Shop::NeedsRecheck => error
    redirect_to shop_path, alert: error.message
  end

  private

  # The draft key from the address round trip when it is a well-formed one, else a fresh random key.
  def draft_key
    draft = params[:draft]
    draft.is_a?(String) && draft.match?(Orders::AddressLookup::DRAFT_FORMAT) ? draft : SecureRandom.hex(16)
  end

  # What the address step shows: the person's unexpired list for this draft, if they loaded one. Never cached anywhere.
  def load_address_step(prize)
    response.headers["Cache-Control"] = "no-store"
    @address_offer = AddressOffer.live_for(current_user, @idempotency_key)
    @address_offer_expired = @address_offer.nil? && AddressOffer.expired_for?(current_user, @idempotency_key)
    @lookup = { purpose: "checkout", item: prize.key, draft: @idempotency_key }
  end
end
