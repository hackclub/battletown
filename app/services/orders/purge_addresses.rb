module Orders
  # Keeps shipping addresses only as long as the parcel needs them (docs/CONTRACT.md, "Shipping addresses").
  #
  #   cancelled or refunded      deleted straight away (Orders::Transition calls `after_transition`)
  #   shipped or fulfilled       `purge_after` is set to that moment + `address_retention_days` (30); the earlier of the two wins
  #   `call` (rake orders:purge_addresses, daily; also tried after every status change) deletes every address that is due
  #
  # Each deleted address writes one `address_purged` history entry on its order (system actor, no content). Idempotent and safe to
  # run twice or at the same time as itself: a row is only counted and written about by whoever really deleted it.
  # `purge_offers` deletes the expired and used address offers (rake orders:purge_address_offers).
  module PurgeAddresses
    BATCH = 200

    module_function

    # Called by Orders::Transition inside its transaction after the order changed. One small call for every move.
    def after_transition(order, by: nil)
      address = OrderAddress.find_by(order_id: order.id)
      return unless address

      if order.cancelled? || order.refunded?
        deleted = delete!(address, order)
        AdminAudit.record!(actor: by, action: "order_address_purged", subject: order, metadata: { order_id: order.id }) if deleted && by
      elsif order.shipped? || order.fulfilled?
        due = [ order.shipped_at, order.fulfilled_at ].compact.min + Config.current.address_retention_days.days
        address.update_columns(purge_after: [ address.purge_after, due ].compact.min)
      end
    end

    # Deletes every address that is due (its date has come, or its order was cancelled or refunded). Returns how many went.
    def call(now: Time.current, limit: BATCH)
      due = OrderAddress.joins(:order).where("order_addresses.purge_after <= :now OR orders.status IN ('cancelled', 'refunded')", now: now)
                        .order("order_addresses.id").limit(limit).includes(:order)
      due.to_a.count { |address| delete!(address, address.order) }
    end

    # The sweep after a status change: never lets a problem here break the change itself.
    def sweep_quietly
      call
    rescue StandardError => error
      Rails.logger.warn("Address purge sweep failed: #{error.class}")
      0
    end

    def purge_offers(now: Time.current) = AddressOffer.stale(now).delete_all

    def delete!(address, order)
      OrderAddress.transaction do
        next false unless OrderAddress.where(id: address.id).delete_all == 1

        OrderEvent.create!(order: order, actor_kind: "system", action: "address_purged", from_status: order.status, to_status: order.status)
        true
      end
    end
  end
end
