require "application_system_test_case"

# Browser behavior of the whoami check (app/javascript/controllers/whoami_*.js), against the test-only stub route. They run in CI's Chrome;
# locally Chrome 158 may fail at teardown.
class WhoamiSystemTest < ApplicationSystemTestCase
  setup do
    @config = Rails.configuration.x.hca
    @was = [ @config.whoami_enabled, @config.whoami_url ]
    @config.whoami_enabled = true
  end

  teardown { @config.whoami_enabled, @config.whoami_url = @was }

  def stub!(mode) = @config.whoami_url = "/test_support/whoami/#{mode}"

  test "signed in at Hack Club: both buttons read as log in and send the sign-in request" do
    stub!("signed_in")
    visit root_path
    assert_selector ".hero a.cta[data-whoami-state='login'] .cta__label", text: "Log in with Hack Club"
    assert_selector "#final-title ~ a.cta[data-whoami-state='login']", text: "Log in with Hack Club"
    assert_no_text "Sign up for free stickers"
    assert_empty page.all("form#whoami-login-form input", visible: :all).map { |i| i[:name] } - [ "authenticity_token" ]
    # Nothing from whoami is posted to us: the click is the ordinary sign-in request (OmniAuth's request phase, here a redirect to the callback).
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: "ident!whoami-sys", extra: { raw_info: {} })
    first(".hero a.cta").click
    assert_no_current_path "/"
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  test "signed out, an error, or a slow answer change nothing" do
    %w[signed_out error slow].each do |mode|
      stub!(mode)
      visit root_path
      sleep 2.6 if mode == "slow" # past both the 1.5 s limit and the stub's delay: still no late jump
      sleep 0.4
      assert_selector ".hero a.cta .cta__label", text: /Sign up for free stickers/, wait: 1
      assert_no_selector "a.cta[data-whoami-state='login']", wait: 0
    end
  end

  def walk_to_the_pledge
    visit "/onboarding/age"
    find(".transition--welcome").click
    click_button "I'm a teen aged 13–18!"
    find("label.choice", match: :first).click
    click_button "Continue"
    assert_no_selector ".transition", wait: 6
    find("label.choice", text: "Game").click
    click_button "Continue"
    assert_no_selector ".transition", wait: 6
    find("label.choice", text: "1 hour").click
    assert_current_path "/onboarding/signup"
  end

  test "the pledge writes the first name on the signature line as the hold fills" do
    stub!("signed_in")
    walk_to_the_pledge
    assert_no_selector ".pledge__signed-name", wait: 0 # nothing until the hold starts
    button = find(".pledge__hold")
    page.driver.browser.action.click_and_hold(button.native).pause(duration: 0.7).perform
    assert_selector ".pledge__signature .pledge__signed-name", text: "Ada"
    page.driver.browser.action.release.perform
  end

  test "with no name known the signature line stays empty, and a very long name is cut" do
    stub!("signed_out")
    walk_to_the_pledge
    page.driver.browser.action.click_and_hold(find(".pledge__hold").native).pause(duration: 0.5).release.perform
    assert_no_selector ".pledge__signed-name", wait: 0
    stub!("signed_in_long")
    walk_to_the_pledge
    page.driver.browser.action.click_and_hold(find(".pledge__hold").native).pause(duration: 0.5).perform
    assert_selector ".pledge__signed-name", text: /\AA{1,40}\z/
  end
end
