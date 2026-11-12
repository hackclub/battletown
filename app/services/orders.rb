# The order lifecycle (docs/CONTRACT.md, "Orders"). One service per transition (Orders::Hold, Release, Ship, Fulfil, Cancel,
# Refund) plus note and tracking edits, all built on Orders::Transition and the pure table in Orders::StateMachine.
module Orders
  # Everything that goes wrong here is a Shop::Error with a message that is fine to show to a person (no ids, no internals),
  # so every existing `rescue Shop::Error` keeps working.
  class NotAllowed < Shop::Error
    def initialize(msg = "That can't be done to this order.") = super
  end

  # The input is wrong (a reason code that is not on the list, a tracking number with odd characters, a note that is too long).
  class Invalid < Shop::Error
    def initialize(msg = "Please check what you entered.") = super
  end

  # The person already has the most waiting orders they can have.
  class TooManyOpen < Shop::Error
    def initialize(msg = "You already have #{Orders::Config.current.max_open_requested} orders waiting for the team. Wait for one to be sent or cancel one first.") = super
  end
end
