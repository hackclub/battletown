require "test_helper"

# Hack Club Auth's whoami is asked from the browser (see test/system/whoami_test.rb for the behavior). Here: what the server renders, and that
# it never receives or stores anything from it.
class WhoamiTest < ActionDispatch::IntegrationTest
  setup do
    @config = Rails.configuration.x.hca
    @was = [ @config.whoami_enabled, @config.whoami_url ]
  end

  teardown { @config.whoami_enabled, @config.whoami_url = @was }

  def enable!(url = "/test_support/whoami/signed_in")
    @config.whoami_enabled = true
    @config.whoami_url = url
  end

  test "off by default in test: no controller, no hidden form" do
    get root_path
    assert_response :success
    assert_no_match(/data-whoami|whoami-login-form/, response.body)
  end

  test "on: both landing buttons carry the whoami controller and the one hidden sign-in form posts only the CSRF token" do
    enable!
    get root_path
    doc = Nokogiri::HTML(response.body)
    buttons = doc.css("a.cta[data-controller='whoami-login']")
    assert_equal 2, buttons.size
    assert_equal "/test_support/whoami/signed_in", buttons.first["data-whoami-login-url-value"]
    assert_equal "Log in with Hack Club", buttons.first["data-whoami-login-label-value"]
    assert_match(%r{/onboarding}, buttons.first["href"]) # without JavaScript or an answer it is the plain link
    form = doc.at_css("form#whoami-login-form")
    assert_equal "/auth/hack_club", form["action"]
    assert_equal "post", form["method"]
    assert_empty form.css("input[name]").map { |i| i["name"] } - [ "authenticity_token" ] # test has no CSRF token; nothing else may be in it
  end

  test "the stub's name and email never appear in the page" do
    enable!
    get root_path
    assert_no_match(/ada@example\.com|Ada/, response.body)
  end

  test "a visitor already signed in here gets no whoami wiring on the landing buttons" do
    enable!
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: "ident!whoami-int", extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    get root_path
    assert_select "form#whoami-login-form", false
    assert_select "a.cta[data-controller='whoami-login']", false
    assert_select "a.cta .cta__label", text: "Continue setup", minimum: 1 unless response.redirect?
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  test "the pledge's signature line listens only when no name is known yet" do
    enable!
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
    patch onboarding_step_path("project"), params: { user: { project_kind: "game", project_idea: "A game" } }
    patch onboarding_step_path("schedule"), params: { user: { coding_day_names: User::DAYS, coding_time: "18:00", time_zone: "UTC", pace_minutes: "60" } }
    get onboarding_step_path("signup")
    assert_select ".pledge__signature[data-controller='whoami-signature']", 1
    assert_select ".pledge__signature[data-action*='pledge-hold:progress@window']", 1
  end

  test "the stub route answers each mode" do
    get "/test_support/whoami/signed_in"
    assert_equal "Ada", response.parsed_body["first_name"]
    get "/test_support/whoami/signed_out"
    assert_equal false, response.parsed_body["signed_in"]
    get "/test_support/whoami/error"
    assert_response :internal_server_error
  end
end
