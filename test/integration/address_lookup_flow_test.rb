require "test_helper"
require_relative "../support/hca_address_helper"
require_relative "../support/hackatime_helper"

# The rules of the address round trip beyond the happy path: how many addresses, the OpenID Connect checks, who may start it, consent,
# and every way Hack Club Auth can answer badly. All against a fake Hack Club Auth over a real local socket.
class AddressLookupFlowTest < ActionDispatch::IntegrationTest
  include HcaAddressHelper
  include HackatimeHelper # capture_logs

  setup do
    @user = users(:onboarded)
    log_in_checkout_user!(@user)
    start_fake_hca(@user)
    @fake_hca.me_with(FakeHca.address("addr_home", primary: true), FakeHca.address("addr_school"))
    sign_in_for_address(@user)
    @both_tokens = [ FakeHca::ACCESS_TOKEN, FakeHca::REFRESH_TOKEN ].sort
  end

  teardown do
    stop_fake_hca
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rack::Attack.enabled = false
  end

  def back_to_the_page(params = @lookup_params) = shop_item_path(params[:item], draft: params[:draft])

  # --- how many addresses ---

  test "no addresses on file gives the friendly empty state, and the order cannot be placed" do
    @fake_hca.me_with
    params = checkout_params
    load_addresses(params)
    follow_redirect!
    assert_select "#address-empty", /You have no address in Hack Club Auth yet\. Add one there, then come back/
    assert_select ".address-step a[href^='#{Rails.configuration.x.hca.address_portal_url}?return_to=']", text: "Add or edit addresses in Hack Club Auth"
    assert_select "select#address-choice", 0
    assert_select "button[disabled]", text: /Place order/
    assert_empty AddressOffer.find_by!(user: @user, draft_key: params[:draft]).addresses
  end

  test "a single address is listed and nothing is preselected" do
    @fake_hca.me_with(FakeHca.address("addr_only"))
    load_addresses(checkout_params)
    follow_redirect!
    assert_select "select#address-choice option", 2
    assert_select "select#address-choice option[selected]", 0
  end

  test "an address without a usable street, city, name or country is left out and counted" do
    @fake_hca.me_with(FakeHca.address("addr_ok"), FakeHca.address("addr_nocountry", "country" => "Atlantis"), FakeHca.address("addr_nostreet", "line_1" => nil))
    load_addresses(checkout_params)
    follow_redirect!
    assert_select "select#address-choice option", 2
    assert_select ".address-step", /2 addresses in Hack Club Auth can't be used for a parcel/
  end

  test "a country given as a name is turned into its code" do
    @fake_hca.me_with(FakeHca.address("addr_de", "country" => "Germany"))
    params = checkout_params
    load_addresses(params)
    assert_equal "DE", AddressOffer.find_by!(user: @user, draft_key: params[:draft]).addresses.first.country
  end

  test "hidden and bidi-override characters are stripped and text is capped" do
    @fake_hca.me_with(FakeHca.address("addr_odd", "line_1" => "1‮ Example​ Street\u0007", "city" => "C" * 500))
    params = checkout_params
    load_addresses(params)
    address = AddressOffer.find_by!(user: @user, draft_key: params[:draft]).addresses.first
    assert_equal "1 Example Street", address.line_1
    assert_equal 100, address.city.length
  end

  # --- the OpenID Connect checks ---

  test "a callback with the wrong state is refused and nothing is stored or exchanged" do
    params = checkout_params
    start_address_lookup(params)
    finish_address_lookup(state: "not-the-state")
    assert_redirected_to %r{/auth/failure\?message=csrf_detected&strategy=hack_club_address}
    follow_redirect!
    assert_redirected_to back_to_the_page(params)
    assert_match(/couldn't load your addresses/, flash[:alert])
    assert_equal 0, AddressOffer.count
    assert_empty @fake_hca.requests_for("POST", "/oauth/token"), "the code is not even exchanged"
    assert_empty @fake_hca.requests_for("GET", "/api/v1/me")
  end

  test "a missing state is refused too" do
    start_address_lookup(checkout_params)
    get "/auth/hack_club_address/callback", params: { code: "good-code" }
    follow_redirect!
    assert_equal 0, AddressOffer.count
    assert_match(/couldn't load your addresses/, flash[:alert])
  end

  test "an ID token with the wrong nonce is refused and nothing is stored" do
    start_address_lookup(checkout_params)
    @fake_hca.id_token_nonce = "someone-elses-nonce"
    finish_address_lookup
    follow_redirect!
    assert_equal 0, AddressOffer.count
    assert_empty @fake_hca.requests_for("GET", "/api/v1/me")
    assert_match(/couldn't load your addresses/, flash[:alert])
  end

  test "a wrong PKCE verifier makes the token request fail and nothing is stored" do
    start_address_lookup(checkout_params)
    @fake_hca.challenge = "a-different-challenge"
    finish_address_lookup
    assert_equal 0, AddressOffer.count
    assert_empty @fake_hca.requests_for("GET", "/api/v1/me")
  end

  test "the PKCE challenge is S256 and the verifier is sent to the token endpoint" do
    start_address_lookup(checkout_params)
    finish_address_lookup
    token_request = @fake_hca.requests_for("POST", "/oauth/token").first
    assert_operator token_request.form["code_verifier"].to_s.length, :>=, 43
    assert FakeHackatime.pkce_matches?(token_request.form["code_verifier"], @authorize["code_challenge"])
  end

  test "a callback can be used once: replaying it stores nothing new and asks nothing more" do
    start_address_lookup(checkout_params)
    finish_address_lookup
    AddressOffer.delete_all
    finish_address_lookup(state: @authorize["state"])
    assert_equal 0, AddressOffer.count
    assert_equal 1, @fake_hca.requests_for("GET", "/api/v1/me").size
  end

  test "the account that answers must be the signed-in person: a mismatch keeps nothing, revokes the token and says so" do
    @fake_hca.sub = "ident!someone-else"
    params = checkout_params
    load_addresses(params)
    assert_redirected_to back_to_the_page(params)
    assert_match(/wasn't the Hack Club account you're signed in/, flash[:alert])
    assert_equal 0, AddressOffer.count
    assert_empty @fake_hca.requests_for("GET", "/api/v1/me"), "no addresses of another account are even fetched"
    assert_equal @both_tokens, @fake_hca.revoked_tokens.sort
  end

  # --- who may start it ---

  test "not signed in: the start is refused, no offer is made and no request leaves for Hack Club Auth" do
    delete logout_path
    assert_nil start_address_lookup(checkout_params)
    assert_redirected_to %r{/auth/failure\?message=not_signed_in&strategy=hack_club_address}
    follow_redirect!
    assert_redirected_to root_path
    assert_equal 0, AddressOffer.count
  end

  test "a callback with nobody signed in is refused before any code is exchanged" do
    start_address_lookup(checkout_params)
    delete logout_path
    finish_address_lookup
    assert_response :redirect
    assert_empty @fake_hca.requests_for("POST", "/oauth/token")
    assert_equal 0, AddressOffer.count
  end

  test "someone who has not finished onboarding cannot start it" do
    @user.update_columns(onboarded_at: nil, onboarding_step: 1)
    assert_nil start_address_lookup(checkout_params)
    assert_equal 0, AddressOffer.count
  end

  test "a callback with no pending checkout (a stale link, a forged request) is refused before the code is exchanged" do
    get "/auth/hack_club_address/callback", params: { code: "good-code", state: "x" }
    assert_response :redirect
    assert_empty @fake_hca.requests_for("POST", "/oauth/token")
    assert_equal 0, AddressOffer.count
  end

  test "a pending checkout older than 15 minutes is forgotten, but the token that was issued is still revoked" do
    start_address_lookup(checkout_params)
    travel 16.minutes do
      finish_address_lookup
      assert_equal 0, AddressOffer.count
      assert_redirected_to shop_path
      assert_match(/took too long/, flash[:alert])
      assert_equal @both_tokens, @fake_hca.revoked_tokens.sort
    end
  end

  test "the start only accepts a checkout this person may really make" do
    bad = [
      checkout_params("nope"),
      checkout_params("signup_sticker"),
      checkout_params("tshirt", draft: "short"),
      { purpose: "checkout", item: "tshirt" },
      { purpose: "change", order_id: "999999999" },
      { purpose: "something-else", item: "tshirt", draft: SecureRandom.hex(16) },
      { purpose: [ "checkout" ], item: "tshirt", draft: SecureRandom.hex(16) },
      {}
    ]
    bad.each do |params|
      assert_nil start_address_lookup(params), "should refuse #{params.inspect}"
      assert_redirected_to %r{/auth/failure\?message=invalid_request&strategy=hack_club_address}
    end
    assert_empty @fake_hca.requests, "nothing reached Hack Club Auth"
  end

  test "a draft that already made an order cannot start another lookup" do
    key = SecureRandom.hex(16)
    buy(@user, "tshirt", key: key)
    assert_nil start_address_lookup(checkout_params("tshirt", draft: key))
  end

  test "an item that is not posted, or archived, cannot start a lookup: non-physical ordering never touches Hack Club Auth" do
    ShopItem.find_by!(key: "keychain").update!(requires_shipping: false)
    assert_nil start_address_lookup(checkout_params("keychain"))
    ShopItem.find_by!(key: "poster").update!(active: false)
    assert_nil start_address_lookup(checkout_params("poster"))
    assert_empty @fake_hca.requests
  end

  test "someone else's order cannot be the subject of a change-address lookup" do
    other = users(:new_user)
    give_coins(verified!(other), 100)
    order = buy(other, "tshirt", address: true)
    assert_nil start_address_lookup(purpose: "change", order_id: order.id.to_s)
  end

  test "an order that has been sent cannot be the subject of a change-address lookup" do
    order = buy(@user, "tshirt", address: true)
    order.update_columns(status: "shipped", shipped_at: Time.current)
    assert_nil start_address_lookup(purpose: "change", order_id: order.id.to_s)
  end

  test "starting is a CSRF-protected POST: without the token it does not go to Hack Club Auth" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post "/auth/hack_club_address", params: checkout_params
    assert_not response.location.to_s.start_with?(@fake_hca.url)
    assert_empty @fake_hca.requests
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "a GET to the start is not a start" do
    get "/auth/hack_club_address", params: checkout_params
    assert_not response.location.to_s.start_with?(@fake_hca.url) if response.redirect?
    assert_empty @fake_hca.requests
  end

  # --- consent ---

  test "pressing Deny at Hack Club Auth is a choice, not an error" do
    params = checkout_params
    start_address_lookup(params)
    get "/auth/hack_club_address/callback", params: { error: "access_denied", state: @authorize["state"] }
    follow_redirect!
    assert_redirected_to back_to_the_page(params)
    assert_nil flash[:alert]
    assert_match(/No problem/, flash[:notice])
    assert_equal 0, AddressOffer.count
  end

  # --- what Hack Club Auth can answer ---

  {
    "a 401 (the token was not accepted)" => [ [ 401, { "error" => "invalid_auth" } ], /didn't accept that sign in/ ],
    "a 403 (the app may not read addresses)" => [ [ 403, { "error" => "not_authorized" } ], /Address lookup isn't available yet/ ],
    "a 404" => [ [ 404, {} ], /Address lookup isn't available yet/ ],
    "a 429" => [ [ 429, "slow your roll!" ], /couldn't reach Hack Club Auth/ ],
    "a 500" => [ [ 500, "oops" ], /couldn't reach Hack Club Auth/ ],
    "a 503" => [ [ 503, "" ], /couldn't reach Hack Club Auth/ ],
    "bad JSON" => [ [ 200, "<html>not json" ], /couldn't read/ ],
    "JSON of the wrong shape" => [ [ 200, [ 1, 2 ].to_json ], /couldn't read/ ],
    "an unexpected status" => [ [ 418, {} ], /couldn't read/ ],
    "a redirect" => [ [ 302, "", { "Location" => "http://127.0.0.1:1/elsewhere" } ], /couldn't read/ ],
    "an oversize answer" => [ [ 200, "x" * (Hca::Http::MAX_BYTES + 10) ], /couldn't read/ ],
    "a grant without the address scope" => [ [ 200, { "identity" => { "id" => "x" }, "scopes" => %w[openid] } ], /Address lookup isn't available yet/ ]
  }.each do |name, (answer, message)|
    test "#{name} from /api/v1/me gives a friendly message, stores nothing and still revokes the token" do
      @fake_hca.me = answer
      params = checkout_params
      load_addresses(params)
      assert_redirected_to back_to_the_page(params)
      assert_match(message, flash[:alert])
      assert_equal 0, AddressOffer.count
      assert_equal @both_tokens, @fake_hca.revoked_tokens.sort
      follow_redirect!
      assert_response :success
      assert_select "form[action='/auth/hack_club_address']", minimum: 1 # they can try again
      assert_select "button[disabled]", text: /Place order/
    end
  end

  test "a slow /api/v1/me times out without hanging the request" do
    @fake_hca.on("GET", "/api/v1/me") { |_req| sleep(0.6); [ 200, { "identity" => { "addresses" => [] } } ] }
    start_address_lookup(checkout_params)
    original = Hca::Http::READ_TIMEOUT
    Hca::Http.send(:remove_const, :READ_TIMEOUT)
    Hca::Http.const_set(:READ_TIMEOUT, 0.2)
    begin
      finish_address_lookup
    ensure
      Hca::Http.send(:remove_const, :READ_TIMEOUT)
      Hca::Http.const_set(:READ_TIMEOUT, original)
    end
    assert_match(/couldn't reach Hack Club Auth/, flash[:alert])
    assert_equal 0, AddressOffer.count
    assert_equal @both_tokens, @fake_hca.revoked_tokens.sort
  end

  test "a failing revoke never breaks the flow" do
    @fake_hca.on("POST", "/oauth/revoke") { |_req| [ 500, "no" ] }
    load_addresses(checkout_params)
    assert_equal 1, AddressOffer.count
  end

  test "an error response never puts the provider's words or the token into the log or the page" do
    @fake_hca.me = [ 500, "Internal error for #{FakeHca::ACCESS_TOKEN} at +15555550123 Example Street" ]
    page = nil
    logs = capture_logs do
      load_addresses(checkout_params)
      follow_redirect!
      page = response.body
    end
    [ FakeHca::ACCESS_TOKEN, "Example Street", "+15555550123" ].each do |secret|
      assert_not_includes logs, secret
      assert_not_includes page, secret
    end
  end

  # --- limits and policy ---

  test "starting a lookup is limited per person" do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    Orders::Config.current.address_lookups_per_10_minutes.times { post "/auth/hack_club_address", params: checkout_params }
    post "/auth/hack_club_address", params: checkout_params
    assert_response :too_many_requests
  end

  test "the confirm page's Content-Security-Policy lets the form go to Hack Club Auth" do
    get shop_item_path("tshirt")
    form_action = response.headers["Content-Security-Policy"].to_s[/form-action [^;]+/]
    assert_includes form_action, @hca_before.first, "the form posts to this app, which redirects to the Hack Club Auth origin"
  end

  test "the buttons that leave for Hack Club Auth turn Turbo off" do
    get shop_item_path("tshirt", draft: SecureRandom.hex(16))
    assert_select "form[action='/auth/hack_club_address'][data-turbo=false]", 1
  end
end
