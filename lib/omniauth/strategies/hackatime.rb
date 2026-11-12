require "omniauth-oauth2"

module OmniAuth
  module Strategies
    # Hackatime OAuth (Doorkeeper). Provider name "hackatime": POST /auth/hackatime, GET /auth/hackatime/callback.
    # Only the Hackatime user id is read from the profile (scope `profile`, GET /api/v1/authenticated/me); nothing
    # else about the person is exposed to the app. Linking is additive to Hack Club Auth sign-in, so the request
    # phase refuses unless the visitor already has a signed-in session (the key is configurable).
    class Hackatime < OmniAuth::Strategies::OAuth2
      option :name, "hackatime"
      option :pkce, true
      option :scope, "profile read"
      option :authorize_options, [ :scope ]
      option :signed_in_session_key, "user_id"
      option :client_options,
        site: "https://hackatime.hackclub.com",
        authorize_url: "/oauth/authorize",
        token_url: "/oauth/token",
        auth_scheme: :request_body,
        connection_opts: { request: { open_timeout: 5, timeout: 10 } }

      uid { raw_info["id"].to_s }

      info { {} }

      credentials do
        hash = { "token" => access_token.token, "scope" => (access_token.params["scope"].presence || options.scope) }
        hash["refresh_token"] = access_token.refresh_token if access_token.refresh_token
        hash["expires_at"] = access_token.expires_at if access_token.expires_at
        hash
      end

      def request_phase
        key = options.signed_in_session_key
        return fail!(:not_signed_in) if key && session[key].blank?

        super
      end

      # The registered redirect URI, without the code and state query string the base class would append.
      def callback_url
        options.redirect_uri.presence || (full_host + callback_path)
      end

      def raw_info
        @raw_info ||= access_token.get("/api/v1/authenticated/me").parsed
      end
    end
  end
end
