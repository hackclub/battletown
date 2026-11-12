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

  # Shipping address problems at checkout or when changing it (docs/CONTRACT.md, "Shipping addresses"). All friendly Shop::Errors;
  # the address pages show the message next to the dropdown.
  class AddressError < Shop::Error; end

  # A physical item was ordered without choosing where to send it.
  class AddressRequired < AddressError
    def initialize(msg = "Choose where to send it first: get your addresses from Hack Club Auth and pick one.") = super
  end

  # The list of addresses was already used or timed out (15 minutes), so it was forgotten to keep it safe.
  class AddressOfferExpired < AddressError
    def initialize(msg = "That took a while, so we forgot your addresses to keep them safe. Press the button to load them again.") = super
  end

  # The address id is not one in the person's own current list (a stale page, or a tampered form).
  class AddressNotOffered < AddressError
    def initialize(msg = "That address isn't one we loaded for you just now. Load your addresses again and pick one.") = super
  end

  # Staff tried to mark a physical order shipped when there is no address to send it to.
  class NeedsAddress < Shop::Error
    def initialize(msg = "Needs an address: the buyer has not chosen where to send this yet. Ask them to pick one on their order page, or ship it with the override and a reason.") = super
  end
end
