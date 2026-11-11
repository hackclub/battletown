# Hack Club Auth (OIDC). Create an app at https://auth.hackclub.com (Developer Apps)
# with redirect URI "#{APP_URL}/auth/hack_club/callback".
OmniAuth.config.logger = Rails.logger
OmniAuth.config.allowed_request_methods = [ :post ]
# Route failures (bad state, denied consent, ...) to /auth/failure in every environment,
# instead of raising the OmniAuth exception page in development.
OmniAuth.config.failure_raise_out_environments = []

Rails.application.config.middleware.use OmniAuth::Builder do
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
end
