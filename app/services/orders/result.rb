module Orders
  # What a transition returns. `outcome` is :done (something changed, `event` is the history row) or :unchanged (the order was
  # already where the action leads, so nothing was written and nobody was refunded twice).
  Result = Data.define(:order, :event, :outcome) do
    def changed? = outcome == :done

    def unchanged? = outcome == :unchanged
  end
end
