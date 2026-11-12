module Orders
  # The pending checkout a Hack Club Auth address round trip belongs to. The start (the OmniAuth request phase) calls `start`,
  # which checks the request names something this person may really do and returns a small Hash of plain ids that goes into
  # the session; the callback calls `consume`, which takes it out (so a callback can be used once) and refuses an old one.
  # Nothing about an address is ever in it.
  #
  #   purpose "checkout"  a physical, active item and the draft key (the idempotency key the confirm page made)
  #   purpose "sticker"   the free signup sticker (not yet claimed), draft key "sticker"
  #   purpose "change"    one of the person's own orders that is still requested or on hold, draft key "order-<id>"
  module AddressLookup
    MAX_AGE = 15.minutes
    DRAFT_FORMAT = /\A[0-9a-f]{32}\z/
    PURPOSES = %w[checkout sticker change].freeze

    module_function

    # Returns the context Hash to remember, or nil when the request is not one this person may make.
    def start(user_id:, params:, now: Time.current)
      user = User.find_by(id: user_id)
      return nil unless user&.onboarded?

      purpose = text(params, "purpose")
      context = case purpose
      when "checkout" then checkout_context(user, params)
      when "sticker" then sticker_context(user)
      when "change" then change_context(user, params)
      end
      context&.merge("purpose" => purpose, "at" => now.to_i)
    end

    # Takes the pending context out of the session; nil when there is none or it is older than MAX_AGE.
    def consume(session, now: Time.current)
      context = session.delete("address_lookup")
      return nil unless context.is_a?(Hash)

      context = context.stringify_keys
      return nil unless PURPOSES.include?(context["purpose"]) && context["draft"].is_a?(String) && context["at"].to_i >= (now - MAX_AGE).to_i

      context
    end

    # Where the person goes back to once the round trip is over (success or not).
    def return_path(context)
      context = context.stringify_keys
      routes = Rails.application.routes.url_helpers
      case context["purpose"]
      when "checkout" then routes.shop_item_path(context["item"], draft: context["draft"])
      when "sticker" then routes.shop_sticker_path
      when "change" then routes.address_order_path(context["order_id"])
      end
    end

    # The same place as a full URL on this site (what Hack Club Auth's address page needs as `return_to`).
    def return_url(context) = URI.join(Rails.configuration.x.hca.address_redirect_uri, return_path(context)).to_s

    def checkout_context(user, params)
      prize = Prize.find(text(params, "item"))
      draft = text(params, "draft")
      return nil unless prize&.active? && !prize.free_signup? && prize.requires_shipping? && draft.match?(DRAFT_FORMAT)
      return nil if Order.exists?(user_id: user.id, idempotency_key: draft)

      { "item" => prize.key, "draft" => draft }
    end

    def sticker_context(user)
      prize = Prize.free_signup
      return nil unless prize&.requires_shipping? && !Order.exists?(user_id: user.id, kind: "signup_sticker")

      { "item" => prize.key, "draft" => "sticker" }
    end

    def change_context(user, params)
      id = text(params, "order_id")
      return nil unless id.match?(/\A\d{1,12}\z/)

      order = user.orders.find_by(id: id.to_i)
      return nil unless order&.address_changeable?

      { "order_id" => order.id, "draft" => "order-#{order.id}" }
    end

    # Only plain strings are accepted (a nested or array param becomes "").
    def text(params, name) = params[name].is_a?(String) ? params[name].strip : ""
    private_class_method :checkout_context, :sticker_context, :change_context, :text
  end
end
