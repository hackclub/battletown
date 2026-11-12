module Orders
  # Where a tracking number can be followed. Known carriers (config/orders.yml, `carriers`) map to their public tracking page; a
  # carrier without a page (post, other) or an unknown one shows the number only. A link is built only when the page is on
  # https and the number is plain (letters, digits, spaces, hyphens: the same rule the order enforces), and the number is URL
  # encoded with its spaces removed, so nothing a person typed can change the address or smuggle in a scheme. Links are always
  # rendered with `rel="noopener noreferrer nofollow"` (see TrackingLinkHelper).
  #
  #   Orders::TrackingLink.for(order)  # => Link(url: "https://...", carrier: "UPS", number: "1Z...") or nil
  module TrackingLink
    Link = Data.define(:url, :carrier, :number) do
      def linked? = url.present?
    end

    SAFE_NUMBER = /\A[A-Za-z0-9][A-Za-z0-9 -]{0,59}\z/

    module_function

    def for(order)
      return nil unless order.tracking_number.present?

      build(order.tracking_carrier, order.tracking_number, order.tracking_label)
    end

    def build(carrier_key, number, label = nil, config: Config.current)
      number = number.to_s.squish
      return nil if number.empty?

      carrier = config.carrier(carrier_key)
      name = carrier_name(carrier, carrier_key, label)
      Link.new(url: url_for(carrier, number), carrier: name, number: number)
    end

    def url_for(carrier, number)
      return nil unless carrier&.url && number.match?(SAFE_NUMBER)

      url = carrier.url.gsub("{number}", ERB::Util.url_encode(number.delete(" ")))
      uri = URI.parse(url)
      uri.scheme == "https" && uri.host.present? ? uri.to_s : nil
    rescue URI::InvalidURIError
      nil
    end

    # "UPS", or for "other" the short label staff typed ("Local courier"), else the plain word.
    def carrier_name(carrier, key, label)
      return label.to_s.squish.truncate(Order::TRACKING_LABEL_MAX) if key.to_s == "other" && label.present?

      carrier ? carrier.name : "Carrier"
    end
  end
end
