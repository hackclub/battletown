module Orders
  # Staff parks a waiting order (a stock problem, a question for the buyer). The coins stay spent, nothing is sent, and the
  # buyer still sees "Requested". Repeating it on an order that is already on hold changes nothing.
  class Hold < Transition
    private

    def action = "hold"

    def refusal = "Only an order that is waiting for the team can be put on hold."
  end
end
