module Admin
  # The staff order queue: requested orders first, filter by status and kind, mark fulfilled, cancel with refund.
  # Shows the person's display name, Slack id and verification status (staff need them to arrange delivery over Slack);
  # no address exists anywhere in this app. Every action goes through the Shop services.
  class OrdersController < BaseController
    LIMIT = 200

    before_action :set_order, only: %i[fulfill cancel]

    def index
      @status = Order::STATUSES.include?(params[:status]) ? params[:status] : nil
      @kind = Order::KINDS.include?(params[:kind]) ? params[:kind] : nil
      scope = Order.includes(:user).queue_order
      scope = scope.where(status: @status) if @status
      scope = scope.where(kind: @kind) if @kind
      @orders = scope.limit(LIMIT).to_a
      @requested_count = Order.where(status: "requested").count
    end

    def fulfill
      Shop::Fulfill.call(order: @order, by: current_user)
      redirect_to back_path, notice: "Marked #{@order.display_name} fulfilled."
    rescue Shop::Error => error
      redirect_to back_path, alert: error.message
    end

    def cancel
      Shop::Cancel.call(order: @order, by: current_user)
      redirect_to back_path, notice: "Cancelled #{@order.display_name}#{' and refunded the coins' if @order.coins.positive?}."
    rescue Shop::Error => error
      redirect_to back_path, alert: error.message
    end

    private

    def set_order = @order = Order.find(params[:id])

    # Keep the filters the staff member was looking at.
    def back_path = admin_orders_path(status: filter_param(:status, Order::STATUSES), kind: filter_param(:kind, Order::KINDS))

    def filter_param(name, allowed) = (params[name] if allowed.include?(params[name]))
  end
end
