require_relative "fake_hca"
require_relative "shop_helper"

# Drives the REAL shipping-address round trip in integration tests: POST /auth/hack_club_address (the OmniAuth strategy), the
# redirect to a fake Hack Club Auth, and the callback with its state, nonce and PKCE, against FakeHca. Nothing here reaches the network.
module HcaAddressHelper
  include ShopTestHelper

  # Starts a fake Hack Club Auth for `user` (its ID tokens carry the user's Hack Club Auth id unless `sub` says otherwise) and points the app at it.
  def start_fake_hca(user, sub: user.hca_uid)
    @fake_hca = FakeHca.new(sub: sub)
    @hca_before = [ Rails.configuration.x.hca.issuer, SWD.url_builder, SWD.cache ]
    Rails.configuration.x.hca.issuer = @fake_hca.url
    SWD.url_builder = URI::HTTP
    SWD.cache = HcaDiscoveryCache.new
    @fake_hca
  end

  def stop_fake_hca
    return unless @fake_hca

    Rails.configuration.x.hca.issuer, SWD.url_builder, SWD.cache = @hca_before
    @fake_hca.stop
    @fake_hca = nil
  end

  # Signs the user in through the sign-in provider's test mode (no request to the fake).
  def sign_in_for_address(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    OmniAuth.config.test_mode = false
  end

  # POSTs the start of the round trip. Returns the authorize parameters the fake Hack Club Auth received (nil if the app refused to start).
  def start_address_lookup(params)
    @lookup_params = params
    post "/auth/hack_club_address", params: params
    return nil unless response.location.to_s.start_with?(@fake_hca.url)

    Rack::Utils.parse_query(URI(response.location).query).tap do |authorize|
      @fake_hca.challenge = authorize["code_challenge"]
      @fake_hca.id_token_nonce = authorize["nonce"]
      @authorize = authorize
    end
  end

  # The browser coming back from the fake Hack Club Auth.
  def finish_address_lookup(code: "good-code", state: @authorize&.fetch("state"), **extra)
    get "/auth/hack_club_address/callback", params: { code: code, state: state }.merge(extra).compact
  end

  # A whole successful round trip for a checkout draft; leaves the response at the redirect back to the page.
  def load_addresses(params)
    assert start_address_lookup(params), "the round trip should have started"
    finish_address_lookup
  end

  def checkout_params(prize_key = "tshirt", draft: SecureRandom.hex(16)) = { purpose: "checkout", item: prize_key, draft: draft }

  def log_in_checkout_user!(user, coins: 200)
    verified!(user)
    user.update_columns(onboarded_at: Time.utc(2026, 11, 1), onboarding_step: 4)
    give_coins(user, coins)
  end
end
