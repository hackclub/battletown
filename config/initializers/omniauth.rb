# Hack Club Auth (OIDC). Create an app at https://auth.hackclub.com (Developer Apps)
# with redirect URI "#{APP_URL}/auth/hack_club/callback".
OmniAuth.config.logger = Rails.logger
OmniAuth.config.allowed_request_methods = [ :post ]

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect,
    name: :hack_club,
    issuer: Rails.configuration.x.hca.issuer,
    discovery: true,
    scope: %i[openid profile email slack_id verification_status],
    response_type: :code,
    pkce: true,
    client_auth_method: :post,
    client_options: {
      identifier: ENV["HCA_CLIENT_ID"] || Rails.application.credentials.dig(:hca, :client_id),
      secret: ENV["HCA_CLIENT_SECRET"] || Rails.application.credentials.dig(:hca, :client_secret),
      redirect_uri: Rails.configuration.x.hca.redirect_uri
    }
end
