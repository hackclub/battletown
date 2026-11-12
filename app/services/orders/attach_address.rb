module Orders
  # Copies the address a person chose from their Hack Club Auth list into an order. Two doors:
  #
  #   Orders::AttachAddress.for_new_order!(order:, user:, draft_key:, address_id:)   at checkout, inside the transaction that
  #       makes the order (Orders::Place / Shop::ClaimSticker), so the order and its address exist together or not at all
  #   Orders::AttachAddress.replace!(order:, by:, address_id:)                       the buyer's "Change address", while the order
  #       is requested or on hold
  #
  # The browser only ever sends an address id. It is looked up in the person's own unexpired, unused offer (AddressOffer); text from
  # a browser is never read. The offer is emptied and marked used the moment its address is copied. Raises a friendly
  # Orders::AddressRequired / AddressOfferExpired / AddressNotOffered / NotAllowed; nothing is saved then.
  module AttachAddress
    module_function

    def for_new_order!(order:, user:, draft_key:, address_id:)
      address, offer = chosen(user, draft_key, address_id)
      record = OrderAddress.new(order: order, user: user).copy_from(address)
      save!(record)
      offer.use!
      record
    end

    # Under the owner's and then the order's row lock (CONTRACT, "Row lock order"), like every other change to an order.
    def replace!(order:, by:, address_id:)
      raise NotAllowed, "That order's address can't be changed any more." unless by&.id == order.user_id

      User.find(order.user_id).with_lock do
        order.lock!
        raise NotAllowed, "That order's address can't be changed any more." unless order.address_changeable?

        address, offer = chosen(by, "order-#{order.id}", address_id)
        record = order.address || OrderAddress.new(order: order, user: by)
        record.copy_from(address)
        save!(record)
        offer.use!
        OrderEvent.create!(order: order, actor_kind: "buyer", action: "address_changed", from_status: order.status, to_status: order.status)
        record
      end
    end

    def chosen(user, draft_key, address_id)
      raise AddressRequired if address_id.blank?

      offer = AddressOffer.live_for(user, draft_key) or raise AddressOfferExpired
      address = offer.find_address(address_id.to_s) or raise AddressNotOffered
      [ address, offer ]
    end

    def save!(record)
      record.save!
    rescue ActiveRecord::RecordInvalid
      raise AddressNotOffered, "That address can't be used for a parcel (it needs a name, a street, a city and a country). Fix it in Hack Club Auth, then load your addresses again."
    end
    private_class_method :chosen, :save!
  end
end
