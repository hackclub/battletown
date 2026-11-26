require "test_helper"

class PagesTest < ActionDispatch::IntegrationTest
  test "known referral slug is remembered and redirects home" do
    get "/stardance"
    assert_redirected_to root_path
    assert_equal "stardance", session[:referral_source]
  end

  test "every program slug records the session referral" do
    %w[haven stardance terra].each do |slug|
      get "/#{slug}"
      assert_redirected_to root_path
      assert_equal slug, session[:referral_source]
      reset!
    end
  end

  test "survey answers are not attribution slugs" do
    %w[google search friend hack_club other youtube].each do |key|
      get "/#{key}"
      assert_response :not_found, key
      assert_nil session[:referral_source]
    end
  end

  test "first touch wins" do
    get "/haven"
    get "/terra"
    assert_equal "haven", session[:referral_source]
  end

  test "unknown slug is a 404, not a catch-all" do
    get "/definitely-not-real"
    assert_response :not_found
    assert_nil session[:referral_source]
  end

  test "landing renders for visitors with a call to action that opens onboarding" do
    get "/"
    assert_response :success
    assert_select "a.cta[href='#{onboarding_path}']"
  end

  test "the dashboard requires login, onboarding starts anonymously" do
    get "/dashboard"
    assert_redirected_to root_path
    get "/onboarding"
    assert_redirected_to onboarding_step_path("age")
  end

  # Battletown has no terms or privacy text of its own: it links to Hack Club's global page (Legal::URL).
  test "/privacy and /terms are permanent redirects to Hack Club's global terms and privacy page, whatever the query" do
    [ "/privacy", "/terms", "/privacy?x=1&next=https://evil.example", "/terms?redirect=//evil.example" ].each do |path|
      get path
      assert_response :moved_permanently, path
      assert_equal "https://hackclub.com/privacy-and-terms/", response.headers["Location"], path
    end
    get "/privacy.html"
    assert_response :not_found
  end

  test "no terms or privacy page of its own is left" do
    assert_not Object.const_defined?(:PagesController), "the controller is gone"
    assert_empty Dir[Rails.root.join("app/views/pages/*")], "so are its views"
    assert_not File.exist?(Rails.root.join("app/views/pages/privacy.html.erb"))
    assert_equal "https://hackclub.com/privacy-and-terms/", Legal::URL
  end

  test "the footer has one link to Hack Club's global terms and privacy policy, in the same tab with rel noopener noreferrer" do
    get "/"
    assert_select "footer nav[aria-label='Legal'] a", 1
    assert_select "footer a[href='https://hackclub.com/privacy-and-terms/'][rel='noopener noreferrer']", text: "Hack Club's terms and privacy policy", count: 1
    assert_select "footer a[target]", 0
    assert_select "footer a[href='/privacy'], footer a[href='/terms']", 0
  end

  test "security headers are set" do
    get "/"
    assert_match(/script-src 'self' 'nonce-/, response.headers["Content-Security-Policy"])
    assert_match(/form-action 'self' https:\/\/auth.hackclub.com/, response.headers["Content-Security-Policy"])
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "strict-origin-when-cross-origin", response.headers["Referrer-Policy"]
    assert_match(/camera=\(\)/, response.headers["Permissions-Policy"])
  end

  test "importmap script carries the CSP nonce" do
    get "/"
    assert_select "script[type='importmap'][nonce]"
  end

  test "skip link is the first focusable element and targets the main landmark" do
    get "/"
    assert_select "a.skip-link[href='#main']", text: "Skip to main content"
    assert_select "main#main[tabindex='-1']"
    first_focusable = css_select("body a, body button, body input").first
    assert_equal "skip-link", first_focusable["class"]
  end
end
