# A person's own orders: list, place (Shop::Purchase) and cancel (Shop::Cancel). Every lookup goes through
# current_user.orders, so someone else's order id is a plain 404.
class OrdersController < ApplicationController
  before_action :require_login, :require_onboarded

  def index
    @orders = current_user.orders.newest_first.to_a
    @total = Coins::Balance.total(current_user)
  end

  def create
    order = Shop::Purchase.call(user: current_user, prize_key: text_param(:prize_key), idempotency_key: text_param(:idempotency_key))
    redirect_to orders_path, notice: "Order placed: #{order.display_name}. The team will message you on Slack to arrange delivery."
  rescue Shop::Error => error
    redirect_to shop_path, alert: error.message
  end

  def cancel
    order = current_user.orders.find(params[:id])
    Shop::Cancel.call(order: order, by: current_user)
    redirect_to orders_path, notice: order.coins.positive? ? "Order cancelled. Your coins are back." : "Order cancelled."
  rescue Shop::Error => error
    redirect_to orders_path, alert: error.message
  end

  private

  # Only plain strings are accepted (a nested or array param becomes "").
  def text_param(name) = params[name].is_a?(String) ? params[name] : ""
end
