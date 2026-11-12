require "application_system_test_case"

# Smoke tests in a real browser: what request tests cannot see (assets served, importmap and Stimulus booting,
# a real form post through OmniAuth).
class LandingSystemTest < ApplicationSystemTestCase
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  test "the landing page renders and its JavaScript boots" do
    visit root_path

    assert_selector "h1 img[alt='Battletown']"
    assert_selector ".landing-hero__tagline", text: /Build projects,\s+get gear/
    assert_selector "h2", text: "How it works"
    assert_selector "h2", text: "FAQ"
    # Turbo is imported by app/javascript/application.js through the importmap; if a pin 404s it never loads.
    assert_equal "object", page.evaluate_script("typeof window.Turbo")
  end

  test "joining from the landing page signs in and goes on to onboarding" do
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
      provider: "hack_club", uid: "ident!system-test", extra: { raw_info: {} }
    )

    visit root_path
    first(".landing-hero button.cta").click

    assert_current_path %r{\A/onboarding}
    assert_equal 1, User.where(hca_uid: "ident!system-test").count
  end
end
