module Orders
  # What a transition returns. `outcome` is :done (something changed, `event` is the history row) or :unchanged (the order was
  # already where the action leads, so nothing was written and nobody was refunded twice).
  Result = Data.define(:order, :event, :outcome) do
    def changed? = outcome == :done

    def unchanged? = outcome == :unchanged
  end

  # The shared shape of every status change: check who is asking, take the owner's row lock and then the order's (CONTRACT, "Row
  # lock order"), repeat harmlessly when the order is already there, check the table in StateMachine, change the order, write
  # the history row, give the coins back when the move refunds, and write the staff audit row, all in one transaction. After it
  # commits, a move that the buyer should hear about is announced (ActiveSupport::Notifications, payload is the order id only).
  #
  #   Orders::Ship.call(order: order, by: admin, tracking: { carrier: "ups", number: "1Z999AA10123456784" })
  #   Orders::Cancel.call(order: order, by: current_user, as: :buyer)
  #
  # `by` is the person acting. `as` is :buyer or :staff (default: staff when `by` is an admin, else buyer); a controller says it
  # out loud so an admin buying something and cancelling it from their own order page is still just a buyer. Raises
  # Orders::NotAllowed (wrong person, wrong status), Orders::Invalid (bad reason, note or tracking): both Shop::Error.
  class Transition
    ANNOUNCED = %w[shipped fulfilled cancelled refunded].freeze

    def self.call(...) = new(...).call

    def initialize(order:, by:, as: nil, reason_code: nil, note: nil)
      @order = order
      @by = by
      @actor = (as || (by&.admin? ? :staff : :buyer)).to_s
      @reason_code = reason_code.to_s.strip.presence
      @note = note.to_s.squish.presence
    end

    def call
      authorize!
      result = nil
      User.find(@order.user_id).with_lock do
        @order.lock!
        result = already? ? Result.new(order: @order, event: nil, outcome: :unchanged) : perform
      end
      announce(result)
      result
    end

    private

    # Subclasses name their action ("hold", "ship" ...); the table is StateMachine::RULES.
    def action = raise(NotImplementedError)

    def refusal = "That can't be done to this order."

    # Anything extra a subclass sets on the order for this move (the tracking for a shipment).
    def extra_attributes = {}

    def target = StateMachine.target(action)

    def staff? = @actor == "staff"

    def authorize!
      raise NotAllowed, refusal unless StateMachine::ACTORS.include?(@actor)
      raise NotAllowed, "Only an admin can do that." if staff? && !@by&.admin?
      raise NotAllowed, refusal if !staff? && @by&.id != @order.user_id
      raise NotAllowed, refusal unless StateMachine.actor_may?(action, @actor)
    end

    def already? = StateMachine.already?(action, @order.status)

    def perform
      from = @order.status
      raise NotAllowed, refusal unless StateMachine.allowed?(action, from, @actor)
      raise NotAllowed, refusal if @actor == "buyer" && @order.signup_sticker?

      reason = checked_reason
      note = checked_note
      change!(**extra_attributes)
      event = OrderEvent.create!(order: @order, actor: (@by if staff?), actor_kind: @actor, action: StateMachine.event_action(action), from_status: from,
                                 to_status: @order.status, reason_code: reason, note: note)
      refund_coins if StateMachine.refunds?(action)
      audit(event)
      Result.new(order: @order, event: event, outcome: :done)
    end

    def change!(**extra)
      stamp = { "ship" => :shipped_at, "fulfil" => :fulfilled_at, "cancel" => :cancelled_at, "refund" => :refunded_at }[action]
      attributes = { status: target }.merge(extra)
      attributes[stamp] = Time.current if stamp
      @order.update!(attributes)
    rescue ActiveRecord::RecordInvalid => error
      raise Invalid, error.record.errors.full_messages.to_sentence
    end

    def checked_reason
      if StateMachine.reason_required?(action, @actor)
        raise Invalid, "Pick a reason." unless Config.current.reason_label(@reason_code)

        @reason_code
      elsif @actor == "staff" && @reason_code
        raise Invalid, "That reason isn't on the list." unless Config.current.reason_label(@reason_code)

        @reason_code
      end
    end

    def checked_note
      return nil unless @note && staff?

      raise Invalid, "Keep the note to #{Config.current.note_max} characters." if @note.length > Config.current.note_max
      raise Invalid, "Notes can't have control characters." if @note.match?(/[[:cntrl:]]/)

      @note
    end

    # One `refund` ledger entry per order, whichever way the order got here (cancelled, shipped then refunded, fulfilled then
    # refunded): the key is the order, so the ledger itself refuses a second one. The free sticker (0 coins) refunds nothing.
    def refund_coins
      return unless @order.coins.positive?

      Coins::Ledger.credit(user: User.find(@order.user_id), amount: @order.coins, kind: "refund", reference: @order,
                           idempotency_key: "shop:refund:#{@order.id}", created_by: staff? ? "staff" : "shop")
    end

    def audit(event)
      return unless staff?

      AdminAudit.record!(actor: @by, action: "order_#{event.action}", subject: @order,
                         metadata: { order_id: @order.id, from_status: event.from_status, to_status: event.to_status, reason_code: event.reason_code,
                                     coins: @order.coins }.compact)
    end

    def announce(result)
      return unless result.changed? && ANNOUNCED.include?(result.event.action)

      ActiveSupport::Notifications.instrument("order_#{result.event.action}.battletown", order_id: @order.id, actor_kind: @actor)
    end
  end
end
