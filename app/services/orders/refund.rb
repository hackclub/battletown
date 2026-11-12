module Orders
  # Staff refunds an order that was already sent (lost parcel, wrong item): `shipped` or `fulfilled` becomes `refunded`, with
  # a reason code, and the coins come back with the one `refund` ledger entry for this order (the same key a cancel uses, so
  # the two can never both pay). Only an admin; the buyer cannot. Refunding a refunded order changes nothing.
  class Refund < Transition
    private

    def action = "refund"

    def refusal = "Only an order that was sent can be refunded."
  end
end
