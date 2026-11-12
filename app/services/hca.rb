# Hack Club Auth, as far as the shipping-address lookup needs it (docs/CONTRACT.md, "Shipping addresses"). Sign-in itself is
# OmniAuth (config/initializers/omniauth.rb); this namespace is only the two calls made with a one-time access token at
# checkout: GET /api/v1/me (Hca::Me) and POST /oauth/revoke (Hca::TokenRevoker). A token is never stored, never logged and
# never part of an error message; neither is anything Hack Club Auth sent back.
module Hca
  # Why a lookup failed, as a code a page can turn into a friendly sentence (Hca::Me::STATES). The message holds the code
  # only: never a body, a token or a status line from the provider.
  #   :not_available  Hack Club Auth refused or does not offer addresses to this app (403, 404, or the grant lacks `address`)
  #   :unauthorized   Hack Club Auth did not accept the one-time token (401)
  #   :unavailable    slow, down, rate limited or unreachable (timeouts, 429, 5xx, network)
  #   :bad_response   it answered with something unusable (too large, not JSON, an unexpected redirect or status)
  class LookupError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code.to_sym
      super(@code.to_s)
    end
  end

  # The Hack Club Auth app's credentials: environment first (config.x.hca, which the test environment pins to fake values so a
  # developer's real ones are never used), Rails credentials as the fallback, like the sign-in provider.
  def self.client_id = Rails.configuration.x.hca.client_id || Rails.application.credentials.dig(:hca, :client_id)

  def self.client_secret = Rails.configuration.x.hca.client_secret || Rails.application.credentials.dig(:hca, :client_secret)
end
