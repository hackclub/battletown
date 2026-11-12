module AdminAudit
  # The shape of an audit event's metadata: small, flat and free of personal data. `normalise` turns what a caller passes
  # (symbol keys, Date values) into the stored form; `problems` lists why a stored hash is not acceptable.
  module Metadata
    MAX_KEYS = 12
    MAX_STRING = 200
    MAX_BYTES = 1500
    KEY_FORMAT = /\A[a-z][a-z0-9_]{0,39}\z/
    # Keys that name personal data or free text. A key like these never belongs in the trail (a `*_id` or `*_count` is fine
    # unless it names an identity: `user_id` yes, `slack_id` no).
    PERSONAL_KEY = /email|mail|name|slack|phone|birth|address|hca|ident|(\A|_)ip(_|\z)|token|password|secret|comment|message|body|text/
    IDENTITY_KEY = /email|slack|hca|ident|phone|address/
    EMAIL = /[^\s@]+@[^\s@]+/
    PHONE = /(?:\d[\s().-]?){10,}/

    module_function

    def normalise(metadata)
      raise ArgumentError, "metadata must be a Hash" unless metadata.is_a?(Hash)

      metadata.to_h { |key, value| [ key.to_s, value.respond_to?(:iso8601) ? value.iso8601 : value ] }
    end

    def problems(metadata)
      return [ "must be a Hash" ] unless metadata.is_a?(Hash)

      found = []
      found << "has more than #{MAX_KEYS} keys" if metadata.size > MAX_KEYS
      found << "is too large" if metadata.to_json.bytesize > MAX_BYTES
      metadata.each do |key, value|
        found << "key #{key.inspect} must be snake_case letters, digits and underscores" unless key.to_s.match?(KEY_FORMAT)
        found << "key #{key.inspect} looks like personal data" if personal_key?(key.to_s)
        found.concat(value_problems(key, value))
      end
      found
    end

    def personal_key?(key)
      return key.match?(IDENTITY_KEY) if key.end_with?("_id", "_count")

      key.match?(PERSONAL_KEY)
    end

    def value_problems(key, value)
      case value
      when Integer, true, false, nil then []
      when String then string_problems(key, value)
      else [ "value of #{key.inspect} must be an integer, boolean, string or nil" ]
      end
    end

    def string_problems(key, value)
      found = []
      found << "value of #{key.inspect} is longer than #{MAX_STRING} characters" if value.length > MAX_STRING
      found << "value of #{key.inspect} contains an email address" if value.match?(EMAIL)
      found << "value of #{key.inspect} contains a phone number" if value.match?(PHONE)
      found
    end
  end
end
