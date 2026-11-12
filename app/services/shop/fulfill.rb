module Shop
  # Staff marks a requested order as fulfilled (the team has arranged delivery). Idempotent: an order that is already
  # fulfilled is returned unchanged and keeps its original fulfilled_at. A cancelled order cannot be fulfilled.
  class Fulfill
    def self.call(...) = new(...).call

    def initialize(order:, by:)
      @order = order
      @by = by
    end

    def call
      raise NotFulfillable, "Only an admin can mark an order fulfilled." unless @by&.admin?

      User.find(@order.user_id).with_lock do
        @order.lock!
        next @order if @order.fulfilled?

        raise NotFulfillable, "A cancelled order can't be fulfilled." unless @order.requested?

        @order.update!(status: "fulfilled", fulfilled_at: Time.current)
        @order
      end
    end
  end
end
