module Orders
  # Staff marks a waiting order as sent, optionally with tracking: { carrier:, number:, label: } (carrier from
  # config/orders.yml, number letters/digits/spaces/hyphens, label only for "other"). An order on hold must be released first.
  # Queues the buyer's "shipped" message once (it never contains the tracking number). Shipping a shipped order changes
  # nothing, including its tracking; edit that with Orders::UpdateTracking.
  class Ship < Transition
    def initialize(tracking: nil, **rest)
      super(**rest)
      @tracking = tracking.to_h.symbolize_keys
    end

    private

    def action = "ship"

    def refusal = "Only an order that is waiting for the team can be marked shipped."

    def extra_attributes = Tracking.attributes(@tracking)
  end
end
