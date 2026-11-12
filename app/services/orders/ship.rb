module Orders
  # Staff marks a waiting order as sent, optionally with tracking: { carrier:, number:, label: } (carrier from
  # config/orders.yml, number letters/digits/spaces/hyphens, label only for "other"). An order on hold must be released first.
  # Queues the buyer's "shipped" message once (it never contains the tracking number). Shipping a shipped order changes
  # nothing, including its tracking; edit that with Orders::UpdateTracking.
  #
  # A physical order with no shipping address is refused ("Needs an address", Orders::NeedsAddress). The one way past it is an
  # explicit override with a reason (`address_override_reason:`, for orders placed before addresses existed or an address handled
  # another way): the reason goes on the order's history and the staff audit trail. Items that need no address, and orders that
  # have one, ship as before. Shipping starts the clock on deleting the address (Orders::PurgeAddresses).
  class Ship < Transition
    OVERRIDE_MAX = 200

    def initialize(tracking: nil, address_override_reason: nil, **rest)
      super(**rest)
      @tracking = tracking.to_h.symbolize_keys
      @override_reason = address_override_reason.to_s.squish.presence
    end

    private

    def action = "ship"

    def refusal = "Only an order that is waiting for the team can be marked shipped."

    def extra_attributes = Tracking.attributes(@tracking)

    def needs_address? = @order.requires_shipping? && !OrderAddress.exists?(order_id: @order.id)

    def overriding? = needs_address? && @override_reason.present?

    def guard!
      return unless needs_address?
      raise NeedsAddress unless @override_reason
      raise Invalid, "Keep the reason to #{OVERRIDE_MAX} characters." if @override_reason.length > OVERRIDE_MAX
      raise Invalid, "Reasons can't have control characters." if @override_reason.match?(/[[:cntrl:]]/)

      @note = [ "Shipped without an address: #{@override_reason}", @note ].compact.join(". ").first(Config.current.note_max)
    end

    def audit_extra = overriding? ? { override: true, override_reason: @override_reason } : {}
  end
end
