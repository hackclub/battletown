module Hca
  # One address from a person's Hack Club Auth account, reduced to what a parcel needs and cleaned. Built only by
  # `from_hca` (a hash out of GET /api/v1/me) or `from_stored` (a hash this app wrote into an address offer). Anything that
  # cannot be posted (no street, city, name or a country code) is refused with nil, so a half-empty address never reaches
  # the dropdown. No label exists in Hack Club Auth, so there is none here.
  Address = Data.define(:id, :recipient_name, :line_1, :line_2, :city, :state, :postal_code, :country, :phone_number, :primary)

  class Address
    include AddressLines

    LIMITS = { recipient_name: 200, line_1: 200, line_2: 200, city: 100, state: 100, postal_code: 30, phone_number: 40 }.freeze
    ID_FORMAT = /\A[A-Za-z0-9_!:.-]{1,80}\z/
    # Control characters, bidi overrides and isolates, zero-width characters and the byte order mark: never part of an address.
    HIDDEN = /[[:cntrl:]\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]/

    # Plain text for one field: NFC, hidden characters removed, white space squeezed, cut to the field's limit (or nil when empty).
    def self.clean(value, limit)
      return nil unless value.is_a?(String) || value.is_a?(Numeric)

      text = value.to_s.unicode_normalize(:nfc).gsub(HIDDEN, " ").squish
      text.presence&.slice(0, limit)
    rescue ArgumentError, Encoding::UndefinedConversionError
      nil
    end

    # Alpha-2 code, or nil when the country is not a real one (a name like "Germany" is turned into DE).
    def self.country_code(value) = AddressTimeZone.country_code_for(value)

    def self.from_hca(hash)
      return nil unless hash.is_a?(Hash)

      raw = hash.stringify_keys
      name = [ raw["first_name"], raw["last_name"] ].filter_map { |part| clean(part, LIMITS[:recipient_name]) }.join(" ").presence
      build(raw["id"].to_s, name, raw["line_1"], raw["line_2"], raw["city"], raw["state"], raw["postal_code"], raw["country"],
            raw["phone_number"], raw["primary"] == true)
    end

    def self.from_stored(hash)
      return nil unless hash.is_a?(Hash)

      raw = hash.stringify_keys
      build(raw["id"].to_s, raw["recipient_name"], raw["line_1"], raw["line_2"], raw["city"], raw["state"], raw["postal_code"],
            raw["country"], raw["phone_number"], raw["primary"] == true)
    end

    def self.build(id, name, line_1, line_2, city, state, postal_code, country, phone, primary)
      return nil unless id.match?(ID_FORMAT)

      address = new(id: id, recipient_name: clean(name, LIMITS[:recipient_name]), line_1: clean(line_1, LIMITS[:line_1]),
                    line_2: clean(line_2, LIMITS[:line_2]), city: clean(city, LIMITS[:city]), state: clean(state, LIMITS[:state]),
                    postal_code: clean(postal_code, LIMITS[:postal_code]), country: country_code(country),
                    phone_number: clean(phone, LIMITS[:phone_number]), primary: primary)
      address.shippable? ? address : nil
    end
    private_class_method :build

    # What a parcel needs at the very least.
    def shippable? = [ recipient_name, line_1, city, country ].all?(&:present?)

    # The dropdown text: street line, city, country (no name, no phone), and "primary" for the one Hack Club Auth marks.
    def option_text = [ line_1, city, country ].join(", ") + (primary ? " (primary)" : "")

    def to_stored = to_h.compact
  end
end
