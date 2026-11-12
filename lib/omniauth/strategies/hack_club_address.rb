require "omniauth_openid_connect"

module OmniAuth
  module Strategies
    # The second Hack Club Auth provider: a one-time, narrow round trip made at checkout to read the person's saved addresses
    # (docs/CONTRACT.md, "Shipping addresses"). Provider name "hack_club_address": POST /auth/hack_club_address (CSRF
    # protected by omniauth-rails_csrf_protection), GET /auth/hack_club_address/callback (AddressCallbacksController).
    #
    # It is NOT a sign-in. The request phase refuses unless someone is already signed in, and unless the request names a
    # real pending checkout (Orders::AddressLookup.start: a physical item they can order, a sticker they have not claimed, or
    # an order of theirs that is still changeable); that checkout is remembered in the session. State, nonce and PKCE are
    # the OpenID Connect gem's. The callback refuses before the code is even exchanged when there is no signed-in person or
    # no pending checkout.
    #
    # Only the scopes `openid address` are asked for. The strategy reads the verified ID token's `sub` (to check the account
    # is the signed-in person's) and hands over the access token; it never calls the userinfo endpoint and never puts a name,
    # email or address claim into the auth hash. The token is used once and revoked by the controller; it is never stored.
    class HackClubAddress < OpenIDConnect
      option :name, "hack_club_address"
      option :signed_in_session_key, "user_id"
      option :context_session_key, "address_lookup"

      def request_phase
        user_id = session[options.signed_in_session_key]
        return fail!(:not_signed_in) if user_id.blank?

        context = Orders::AddressLookup.start(user_id: user_id, params: request.params)
        return fail!(:invalid_request) unless context

        session[options.context_session_key] = context
        super
      end

      def callback_phase
        return fail!(:not_signed_in) if session[options.signed_in_session_key].blank?
        return fail!(:no_pending_request) if session[options.context_session_key].blank?

        super
      end

      # The subject of the verified ID token: Hack Club Auth's id for the person (the same value as users.hca_uid).
      def uid
        id_token = access_token.id_token
        id_token.present? ? decode_id_token(id_token).raw_attributes["sub"].to_s.presence : nil
      end

      def info = {}

      def extra = {}

      def credentials
        { token: access_token.access_token, refresh_token: access_token.refresh_token }
      end
    end
  end
end
