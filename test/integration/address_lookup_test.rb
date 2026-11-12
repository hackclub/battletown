require "test_helper"
require_relative "../support/hca_address_helper"
require_relative "../support/hackatime_helper"

# The shipping-address round trip at checkout, end to end against a fake Hack Club Auth: the OmniAuth strategy (state, nonce, PKCE,
# a signed ID token), the callback controller, Hca::Me, the encrypted offer, token revocation, and what is never kept.
class AddressLookupTest < ActionDispatch::IntegrationTest
  include HcaAddressHelper
  include HackatimeHelper # capture_logs

  setup do
    @user = users(:onboarded)
    log_in_checkout_user!(@user)
    start_fake_hca(@user)
    @fake_hca.me_with(FakeHca.address("addr_home", primary: true), FakeHca.address("addr_school"), FakeHca.address("addr_gran", country: "GB"))
    sign_in_for_address(@user)
  end

  teardown do
    stop_fake_hca
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  test "the happy path: the round trip stores an encrypted offer, revokes the token, and the dropdown lists the addresses" do
    params = checkout_params
    authorize = start_address_lookup(params)

    assert_equal "openid address", authorize["scope"], "only the narrow scopes are asked for"
    assert_equal "S256", authorize["code_challenge_method"]
    assert authorize["state"].present? && authorize["nonce"].present?
    assert_equal "http://localhost:3000/auth/hack_club_address/callback", authorize["redirect_uri"]

    finish_address_lookup
    assert_redirected_to shop_item_path("tshirt", draft: params[:draft])

    offer = AddressOffer.find_by!(user: @user, draft_key: params[:draft])
    assert_equal %w[addr_home addr_school addr_gran], offer.addresses.map(&:id).sort_by { |id| %w[addr_home addr_school addr_gran].index(id) }
    assert_in_delta 15.minutes.from_now.to_f, offer.expires_at.to_f, 5
    assert_equal [ FakeHca::ACCESS_TOKEN, FakeHca::REFRESH_TOKEN ].sort, @fake_hca.revoked_tokens.sort, "both tokens were revoked at once"
    assert_equal "test-hca-client-id", @fake_hca.requests_for("POST", "/oauth/revoke").first.form["client_id"]

    follow_redirect!
    assert_response :success
    assert_select "select#address-choice[name=address_id] option", 4 # the blank choice + three
    assert_select "select#address-choice option", text: "Home Example Street, Exampleville, US (primary)"
    assert_select "select#address-choice option", text: "School Example Street, Exampleville, US"
    assert_select "select#address-choice option", text: "Gran Example Street, Exampleville, GB"
    assert_select "button[disabled]", text: /Place order/
    assert_select "[data-address-id=addr_school]", 1
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "the one-time token is used once and never stored: not in the database, the session, the cookie or the logs" do
    logs = capture_logs do
      load_addresses(checkout_params)
      follow_redirect!
    end

    [ FakeHca::ACCESS_TOKEN, FakeHca::REFRESH_TOKEN ].each do |secret|
      assert_not_includes logs, secret
      assert_not_includes response.headers.to_s, secret
      assert_not_includes response.body, secret
      assert_not_includes cookies.to_hash.values.join, secret
      assert_equal 0, dump_database_rows.scan(secret).size, "the token must not be in any table"
    end
    assert_not_includes logs, "Example Street"
    assert_not_includes logs, "+15555550123"
    assert_not_includes dump_database_rows, "Example Street", "the addresses are encrypted at rest"
  end

  def dump_database_rows
    ActiveRecord::Base.connection.tables.sort.map do |table|
      ActiveRecord::Base.connection.select_rows("SELECT * FROM #{ActiveRecord::Base.connection.quote_table_name(table)}").flatten.join(" ")
    end.join("\n")
  end
end
