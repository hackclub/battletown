# A person's own orders: list, one order's page, place (Orders::Place -> Shop::Purchase, behind the waiting-orders cap) and
# cancel (Orders::Cancel, only while requested). Every lookup goes through current_user.orders, so someone else's order id is
# a plain 404. The buyer sees plain status words and dates only: a hold reads as "Requested", and staff notes, reason codes
# and the staff history never reach these pages.
#
# Physical orders also carry a shipping address (docs/CONTRACT.md, "Shipping addresses"): chosen at checkout from the person's own
# Hack Club Auth addresses, shown on their order page, and changeable (`address`, `update_address`) until the order is sent.
class OrdersController < ApplicationController
  before_action :require_login, :require_onboarded

  def index
    @orders = current_user.orders.newest_first.to_a
    @total = Coins::Balance.total(current_user)
  end

  def show
    @order = current_user.orders.includes(:address).find(params[:id])
    @events = @order.events.for_buyer.oldest_first.to_a
    response.headers["Cache-Control"] = "no-store" if @order.address
  end

  # Physical items are placed together with the address picked on the confirm page (`address_id`, an id from the person's own
  # unexpired offer; address text from a browser is never read). Back, refresh and a double click make one order.
  def create
    prize = Prize.find(text_param(:prize_key))
    shipped = prize.present? && prize.requires_shipping?
    order = Orders::Place.call(user: current_user, prize_key: text_param(:prize_key), idempotency_key: text_param(:idempotency_key),
                               address_id: text_param(:address_id), address_required: shipped, expected_coins: expected_coins)
    redirect_to order_path(order), notice: placed_notice(order, shipped)
  rescue Orders::AddressError => error
    redirect_to shop_item_path(prize.key, draft: text_param(:idempotency_key)), alert: error.message
  rescue Shop::PriceChanged => error
    redirect_to shop_item_path(prize.key, draft: text_param(:idempotency_key)), alert: error.message
  rescue Shop::Error => error
    redirect_to shop_path, alert: error.message
  end

  def cancel
    order = current_user.orders.find(params[:id])
    Orders::Cancel.call(order: order, by: current_user, as: :buyer)
    redirect_to back_to(order), notice: order.coins.positive? ? "Order cancelled. Your coins are back." : "Order cancelled."
  rescue Shop::Error => error
    redirect_to back_to(order), alert: error.message
  end

  # "Change address": the dropdown of the addresses just loaded from Hack Club Auth for this order.
  def address
    @order = current_user.orders.find(params[:id])
    return redirect_to(order_path(@order), alert: "That order's address can't be changed any more.") unless @order.address_changeable?

    response.headers["Cache-Control"] = "no-store"
    @address_offer = AddressOffer.live_for(current_user, "order-#{@order.id}")
    @address_offer_expired = @address_offer.nil? && AddressOffer.expired_for?(current_user, "order-#{@order.id}")
    @lookup = { purpose: "change", order_id: @order.id }
  end

  def update_address
    order = current_user.orders.find(params[:id])
    Orders::AttachAddress.replace!(order: order, by: current_user, address_id: text_param(:address_id))
    redirect_to order_path(order), notice: "Address updated."
  rescue Orders::AddressError => error
    redirect_to address_order_path(order), alert: error.message
  rescue Shop::Error => error
    redirect_to order_path(order), alert: error.message
  end

  private

  # The price the confirm page showed (a plain whole number), or nil when the form did not send one.
  def expected_coins
    text = text_param(:expected_coins)
    Integer(text, 10) if text.match?(/\A\d{1,9}\z/)
  end

  def placed_notice(order, shipped)
    if shipped
      "Order placed: #{order.display_name}. We'll post it to the address you picked."
    else
      "Order placed: #{order.display_name}. The team will message you on Slack to arrange delivery."
    end
  end

  # Back to the page the button was on: the order's own page or the list.
  def back_to(order)
    params[:from] == "order" ? order_path(order) : orders_path
  end

  # Only plain strings are accepted (a nested or array param becomes "").
  def text_param(name) = params[name].is_a?(String) ? params[name] : ""
end
