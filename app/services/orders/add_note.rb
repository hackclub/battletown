module Orders
  # Staff adds a note to an order's history without changing its status (any status, a final one too). The note is a short
  # line of text, staff-only: it is stored on the history row, never shown to the buyer, never put in a message, and never
  # copied into the audit trail (the audit row only says a note was added).
  class AddNote
    def self.call(...) = new(...).call

    def initialize(order:, by:, note:)
      @order = order
      @by = by
      @note = note.to_s.squish
    end

    def call
      raise NotAllowed, "Only an admin can do that." unless @by&.admin?
      raise Invalid, "Write a note first." if @note.empty?
      raise Invalid, "Keep the note to #{Config.current.note_max} characters." if @note.length > Config.current.note_max
      raise Invalid, "Notes can't have control characters." if @note.match?(/[[:cntrl:]]/)

      User.find(@order.user_id).with_lock do
        @order.lock!
        event = OrderEvent.create!(order: @order, actor: @by, actor_kind: "staff", action: "note_added", from_status: @order.status,
                                   to_status: @order.status, note: @note)
        AdminAudit.record!(actor: @by, action: "order_note_added", subject: @order, metadata: { order_id: @order.id, status: @order.status })
        Result.new(order: @order, event: event, outcome: :done)
      end
    end
  end
end
