module Shop
  # Cancels a requested order and gives the coins back with one `refund` ledger entry, exactly once. Only while the
  # order is still requested. `by` is the person cancelling: the order's owner, or an admin. Cancelling an order that
  # is already cancelled returns it unchanged (idempotent, no second refund). The free sticker is not refunded
  # (nothing was paid), and its owner cannot cancel it themselves (they could never claim another).
  class Cancel
    def self.call(...) = new(...).call

    def initialize(order:, by:)
      @order = order
      @by = by
    end

    def call
      owner = User.find(@order.user_id)
      raise NotCancellable unless @by.id == owner.id || @by.admin?

      # Lock order is always user, then order (Purchase takes the user lock first too).
      owner.with_lock do
        @order.lock!
        next @order if @order.cancelled?

        raise NotCancellable unless @order.requested?
        raise NotCancellable if @order.signup_sticker? && @by.id == owner.id

        @order.update!(status: "cancelled", cancelled_at: Time.current)
        if @order.coins.positive?
          Coins::Ledger.credit(user: owner, amount: @order.coins, kind: "refund", reference: @order,
                               idempotency_key: "shop:refund:#{@order.id}", created_by: @by.id == owner.id ? "shop" : "staff")
        end
        @order
      end
    end
  end
end
