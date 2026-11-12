# Hack Club Auth (OIDC). Create an app at https://auth.hackclub.com (Developer Apps)
# with redirect URI "#{APP_URL}/auth/hack_club/callback".
OmniAuth.config.logger = Rails.logger
OmniAuth.config.allowed_request_methods = [ :post ]
# Route failures (bad state, denied consent, ...) to /auth/failure in every environment,
# instead of raising the OmniAuth exception page in development.
OmniAuth.config.failure_raise_out_environments = []

# Hack Club Auth rate limits its public endpoints (HTTP 429 "slow your roll!"), and the OIDC gem
# re-fetches the discovery document (and its signing keys, which ride along on the same object)
# on every sign-in request and callback. Keep successful lookups in process for a short while.
# Failures are never cached, so a 429 is simply retried on the next sign-in. The TTL is short so a
# key rotation heals itself quickly.
class HcaDiscoveryCache
  TTL = 15.minutes

  def initialize(ttl: TTL, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @ttl = ttl.to_f
    @clock = clock
    @entries = {}
    @mutex = Mutex.new
  end

  # Same signature as SWD::Cache#fetch, which the OIDC discovery lookup calls.
  def fetch(key, _options = {})
    cached = @mutex.synchronize { @entries[key] }
    return cached[:value] if cached && cached[:expires_at] > @clock.call

    value = yield
    @mutex.synchronize { @entries[key] = { value: value, expires_at: @clock.call + @ttl } }
    value
  end
end
SWD.cache = HcaDiscoveryCache.new

require Rails.root.join("lib/omniauth/strategies/hackatime")
require Rails.root.join("lib/omniauth/strategies/hack_club_address")

# Hack Club Auth must be reached over https in production (the one-time address token travels to it). A local fake provider (tests,
# the manual browser walk) may use http; the OpenID discovery client then needs to be told so.
if Rails.configuration.x.hca.issuer.start_with?("http://")
  raise "HCA_ISSUER must be an https URL in production" if Rails.env.production?

  SWD.url_builder = URI::HTTP
end

# Hackatime must be reached over https in production (the tokens travel to it); a local fake provider may use http.
hackatime_base_url = Rails.configuration.x.hackatime.base_url
if Rails.env.production? && URI(hackatime_base_url).scheme != "https"
  raise "HACKATIME_URL must be an https URL in production"
end

Rails.application.config.middleware.use OmniAuth::Builder do
  # Account linking, not sign-in: the callback is handled by HackatimeConnectionsController and never creates
  # or signs in a user. Scopes are exactly the two the Hackatime OAuth app has: read and profile.
  provider :hackatime,
    Rails.configuration.x.hackatime.client_id || Rails.application.credentials.dig(:hackatime, :client_id),
    Rails.configuration.x.hackatime.client_secret || Rails.application.credentials.dig(:hackatime, :client_secret),
    scope: Rails.configuration.x.hackatime.scopes,
    redirect_uri: Rails.configuration.x.hackatime.redirect_uri,
    client_options: { site: hackatime_base_url },
    # Read at request time so the provider URL can be pointed at a local fake (tests, HACKATIME_URL) without a reboot.
    setup: ->(env) { env["omniauth.strategy"].options.client_options.site = Rails.configuration.x.hackatime.base_url }

  provider :openid_connect,
    name: :hack_club,
    issuer: Rails.configuration.x.hca.issuer,
    discovery: true,
    # Every scope enabled on the Hack Club Auth app. phone, birthdate and address are requested
    # but deliberately not stored or logged (see User#apply_hca_claims) pending a privacy decision.
    scope: %i[openid profile email name phone birthdate address verification_status slack_id basic_info],
    response_type: :code,
    pkce: true,
    client_auth_method: :post,
    client_options: {
      identifier: ENV["HCA_CLIENT_ID"] || Rails.application.credentials.dig(:hca, :client_id),
      secret: ENV["HCA_CLIENT_SECRET"] || Rails.application.credentials.dig(:hca, :client_secret),
      redirect_uri: Rails.configuration.x.hca.redirect_uri
    }

  # The shipping-address lookup at checkout (docs/CONTRACT.md, "Shipping addresses"): the same Hack Club Auth app, but only the
  # scopes `openid address`, its own callback (register `#{APP_URL}/auth/hack_club_address/callback` on the app too), and only
  # ever for someone who is already signed in. The issuer and credentials are read at request time, like Hackatime's URL.
  provider OmniAuth::Strategies::HackClubAddress,
    issuer: Rails.configuration.x.hca.issuer,
    discovery: true,
    scope: Rails.configuration.x.hca.address_scopes,
    response_type: :code,
    pkce: true,
    client_auth_method: :post,
    client_options: {
      identifier: Rails.configuration.x.hca.client_id || Rails.application.credentials.dig(:hca, :client_id),
      secret: Rails.configuration.x.hca.client_secret || Rails.application.credentials.dig(:hca, :client_secret),
      redirect_uri: Rails.configuration.x.hca.address_redirect_uri
    },
    setup: lambda { |env|
      options = env["omniauth.strategy"].options
      options.issuer = Rails.configuration.x.hca.issuer
      options.client_options.identifier = Rails.configuration.x.hca.client_id || Rails.application.credentials.dig(:hca, :client_id)
      options.client_options.secret = Rails.configuration.x.hca.client_secret || Rails.application.credentials.dig(:hca, :client_secret)
    }
end
