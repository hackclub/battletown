module Orders
  # Staff corrects or adds the tracking of an order that was sent (`shipped` or `fulfilled`). It changes no status and no coins;
  # it writes a `tracking_updated` history row (no number in it) and an `order_tracking_updated` audit row, under the same locks as
  # every transition. Sends nothing to the buyer.
  class UpdateTracking
    def self.call(...) = new(...).call

    def initialize(order:, by:, tracking:)
      @order = order
      @by = by
      @tracking = tracking.to_h.symbolize_keys
    end

    def call
      raise NotAllowed, "Only an admin can do that." unless @by&.admin?

      User.find(@order.user_id).with_lock do
        @order.lock!
        raise NotAllowed, "Tracking can only be changed once the order is sent." unless @order.shipped? || @order.fulfilled?

        attributes = Tracking.attributes(@tracking)
        next Result.new(order: @order, event: nil, outcome: :unchanged) if attributes.all? { |name, value| @order[name] == value }

        begin
          @order.update!(attributes)
        rescue ActiveRecord::RecordInvalid => error
          raise Invalid, error.record.errors.full_messages.to_sentence
        end
        event = OrderEvent.create!(order: @order, actor: @by, actor_kind: "staff", action: "tracking_updated", from_status: @order.status,
                                   to_status: @order.status)
        AdminAudit.record!(actor: @by, action: "order_tracking_updated", subject: @order,
                           metadata: { order_id: @order.id, status: @order.status, tracking_carrier: @order.tracking_carrier }.compact)
        Result.new(order: @order, event: event, outcome: :done)
      end
    end
  end
end
