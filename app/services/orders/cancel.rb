module Orders
  # Cancels an order that has not been sent and gives the coins back with one `refund` ledger entry, exactly once. The buyer
  # may cancel only while `requested` (never the free signup sticker: they could never claim another); staff may also cancel
  # an order on hold, and must pick a reason code (config/orders.yml). Cancelling a cancelled order changes nothing.
  class Cancel < Transition
    private

    def action = "cancel"

    def refusal = "That order can't be cancelled any more."
  end
end
