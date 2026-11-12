# A person's own orders: list, one order's page, place (Orders::Place -> Shop::Purchase, behind the waiting-orders cap) and
# cancel (Orders::Cancel, only while requested). Every lookup goes through current_user.orders, so someone else's order id is
# a plain 404. The buyer sees plain status words and dates only: a hold reads as "Requested", and staff notes, reason codes
# and the staff history never reach these pages.
class OrdersController < ApplicationController
  before_action :require_login, :require_onboarded

  def index
    @orders = current_user.orders.newest_first.to_a
    @total = Coins::Balance.total(current_user)
  end

  def show
    @order = current_user.orders.find(params[:id])
    @events = @order.events.for_buyer.oldest_first.to_a
  end

  def create
    order = Orders::Place.call(user: current_user, prize_key: text_param(:prize_key), idempotency_key: text_param(:idempotency_key))
    redirect_to order_path(order), notice: "Order placed: #{order.display_name}. The team will message you on Slack to arrange delivery."
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

  private

  # Back to the page the button was on: the order's own page or the list.
  def back_to(order)
    params[:from] == "order" ? order_path(order) : orders_path
  end

  # Only plain strings are accepted (a nested or array param becomes "").
  def text_param(name) = params[name].is_a?(String) ? params[name] : ""
end
