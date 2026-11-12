module Orders
  # Turns what staff typed for a shipment ({ carrier:, number:, label: }) into the order's three tracking columns. Blank means
  # "no tracking" (all three nil). The order validates the result (carrier on the list, number characters and length, label only
  # for "other"), so this only normalises: strip, collapse spaces, lower-case the carrier.
  module Tracking
    module_function

    def attributes(input)
      {
        tracking_carrier: input[:carrier].to_s.strip.downcase.presence,
        tracking_number: input[:number].to_s.squish.presence,
        tracking_label: input[:label].to_s.squish.presence
      }
    end
  end
end
