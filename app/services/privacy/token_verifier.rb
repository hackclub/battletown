module Privacy
  # Verifies the bearer token on the data-deletion/export endpoints: an ES256 JWT signed by Hack Club's service
  # (docs/PRIVACY_API.md). This check is the only thing standing between the internet and deleting users, so
  # everything is rejected unless it is exactly as expected. Any failure raises Invalid, which carries no detail
  # (not even which check failed) and never the token. A key server outage raises Jwks::Unavailable instead.
  class TokenVerifier
    ISSUER = "hackclub-privacy".freeze
    DEFAULT_AUDIENCE = "battletown".freeze
    ACTIONS = %w[delete export].freeze
    LEEWAY = 30
    MAX_LIFETIME = 300
    MAX_TOKEN_BYTES = 4096
    MAX_EMAILS = 50

    class Invalid < StandardError; end

    Subject = Data.define(:emails, :slack_id, :identity_id)
    Claims = Data.define(:jti, :request_id, :action, :dry_run, :subject)

    def self.audience = ENV["PRIVACY_AUDIENCE"].presence || DEFAULT_AUDIENCE

    def initialize(jwks: Jwks.current, audience: self.class.audience, now: -> { Time.current.to_i })
      @jwks = jwks
      @audience = audience
      @now = now
    end

    def verify!(token)
      raise Invalid unless token.is_a?(String) && token.bytesize <= MAX_TOKEN_BYTES

      header = unverified_header(token)
      key = @jwks.key_for(header["kid"])
      raise Invalid unless key

      payload, = JWT.decode(token, key, true, algorithms: [ "ES256" ], verify_expiration: false, verify_not_before: false,
                                                verify_iat: false, verify_iss: false, verify_aud: false)
      claims_from(payload)
    rescue JWT::DecodeError, ArgumentError, TypeError, JSON::ParserError
      raise Invalid, cause: nil
    end

    private

    # Reads the header without trusting it: only to pick the key and to refuse anything but ES256/JWT early.
    def unverified_header(token)
      raise Invalid unless token.count(".") == 2

      _, header = JWT.decode(token, nil, false)
      raise Invalid unless header["alg"] == "ES256" && header["typ"] == "JWT" && header["kid"].is_a?(String) && header["kid"].present?

      header
    end

    def claims_from(payload)
      raise Invalid unless payload.is_a?(Hash) && payload["iss"] == ISSUER && payload["aud"] == @audience
      check_times(payload["iat"], payload["exp"])

      action = payload["action"]
      raise Invalid unless ACTIONS.include?(action) && [ true, false ].include?(payload["dry_run"])

      Claims.new(jti: identifier(payload["jti"]), request_id: identifier(payload["request_id"]),
                 action: action, dry_run: payload["dry_run"], subject: subject_from(payload["subject"]))
    end

    def check_times(iat, exp)
      raise Invalid unless iat.is_a?(Integer) && exp.is_a?(Integer)

      now = @now.call
      raise Invalid if exp - iat > MAX_LIFETIME || exp <= iat
      raise Invalid if exp + LEEWAY < now || iat - LEEWAY > now
    end

    # jti and request_id: non-empty printable strings of sane length (request_id is written to the log).
    def identifier(value)
      raise Invalid unless value.is_a?(String) && value.match?(/\A[[:print:]]{1,128}\z/)

      value
    end

    def subject_from(raw)
      raise Invalid unless raw.is_a?(Hash)

      emails = raw.fetch("emails", [])
      raise Invalid unless emails.is_a?(Array) && emails.size <= MAX_EMAILS && emails.all? { |e| e.is_a?(String) && e.bytesize <= 320 }

      Subject.new(emails: emails.map { |e| e.strip.downcase }.reject(&:empty?).uniq,
                  slack_id: optional_string(raw["slack_id"], 64), identity_id: optional_string(raw["identity_id"], 128))
    end

    def optional_string(value, max)
      return if value.nil?
      raise Invalid unless value.is_a?(String) && value.bytesize <= max

      value.strip.presence
    end
  end
end
