module Orders
  # Staff takes an order off hold: it is `requested` again. Sends nothing. Releasing an order that is not on hold changes
  # nothing when it is already requested, and is refused otherwise.
  class Release < Transition
    private

    def action = "release"

    def refusal = "That order isn't on hold."
  end
end
