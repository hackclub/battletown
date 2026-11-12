module Nps
  # The link in the survey DM: /feedback/<token>. A signed (not encrypted) token that says "this person may answer the
  # survey for this prompt window", good for `nps.token_ttl_days`. It is:
  # - purpose-scoped: a token signed for anything else (a session, another feature) never verifies here, and this one
  #   never verifies elsewhere;
  # - tamper-proof: any change to it, and a token signed with another key, fails verification;
  # - single-use in effect: the answer is unique per person and window (nps_responses), so a second use only gets
  #   "you already answered" and changes nothing;
  # - made at send time and never stored, so nothing in the database can be used to build one.
  # It carries only a user id and a date: no name, email or Slack id. It lets someone answer one survey question and
  # nothing else (no page that shows personal data is reachable with it).
  module Token
    PURPOSE = "nps_feedback".freeze
    SALT = "battletown nps feedback v1".freeze
    PATH_FORMAT = /[A-Za-z0-9_=-]{20,400}/ # what a token looks like in the URL; the signature is what decides
    Claims = Data.define(:user_id, :window_date)

    module_function

    def generate(user, window_date, config: Config.current, now: Time.current)
      verifier.generate({ "u" => user.id, "w" => window_date.iso8601 }, purpose: PURPOSE, expires_at: now + config.token_ttl)
    end

    # The Claims, or nil for anything that is not a valid, unexpired token made for this purpose.
    def parse(token)
      return nil unless token.is_a?(String) && token.length.between?(20, 400)

      payload = verifier.verified(token, purpose: PURPOSE)
      return nil unless payload.is_a?(Hash) && payload["u"].is_a?(Integer) && payload["w"].is_a?(String)

      Claims.new(user_id: payload["u"], window_date: Date.iso8601(payload["w"]))
    rescue ArgumentError, ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
      nil
    end

    def verifier
      ActiveSupport::MessageVerifier.new(Rails.application.key_generator.generate_key(SALT), digest: "SHA256", serializer: JSON, url_safe: true)
    end
    private_class_method :verifier
  end
end
