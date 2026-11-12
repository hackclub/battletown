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

  test "landing renders for visitors with a sign up button posting to the auth path" do
    get "/"
    assert_response :success
    assert_select "form[action='/auth/hack_club'][method='post']"
  end

  test "dashboard and onboarding require login" do
    get "/dashboard"
    assert_redirected_to root_path
    get "/onboarding"
    assert_redirected_to root_path
  end

  test "legal pages render" do
    get "/privacy"
    assert_response :success
    get "/terms"
    assert_response :success
  end

  test "legal pages are one readable prose panel with a single h1 and no inline styles" do
    { "/privacy" => "Privacy", "/terms" => "Terms" }.each do |path, heading|
      get path
      assert_select "article.panel .prose", 1
      assert_select "h1", text: heading, count: 1
      assert_select "article .eyebrow", text: "Legal"
      assert_select "[style]", 0
      assert_select "article", text: /placeholder/
    end
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
