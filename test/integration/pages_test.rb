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

  test "docs page is public, has anchored sections and keeps every coding time rule" do
    get "/docs"
    assert_response :success
    assert_select "h1", text: "How Battletown works", count: 1
    %w[how-it-works sign-up hackatime projects ships coins bosses shop rules coding-time valid-ship honesty eligibility fulfillment ordering order-status duties legal].each do |id|
      assert_select "[id='#{id}']", 1, "missing section #{id}"
      assert_select ".docs__toc a[href='##{id}']", 1, "table of contents has no link to #{id}"
    end
    assert_select "[style]", 0
    assert_select "#duties + p", text: "Hack Club does not and cannot pay import duties or customs fees."
    rules = css_select("#coding-time + ul li").map { |li| li.text.squish }.join(" ")
    assert_match(/Hackatime is a free tool that tracks the time you spend coding\./, rules)
    assert_match(/Only time tracked with Hackatime while you build your project counts/, rules)
    assert_match(/Never add extra hours/, rules)
    assert_match(/Reading docs or watching videos counts only once you build something with what you learned/, rules)
    assert_match(/art usually counts only up to about a third of your project time/, rules)
    assert_match(/only count toward one You Ship We Ship program/, rules)
    assert_match(/before the program started does not count/, rules)
    assert_no_match(/TBD|TODO|Hackclub|HackClub|hack club/, response.body.gsub(/hackclub\.[a-z.]+|hackclub\.enterprise/, ""))
  end

  test "docs page is also public with a session and links to the legal pages" do
    get "/docs"
    assert_select "#legal ~ ul a[href='https://hackclub.com/privacy-and-terms']"
    assert_select "footer.site-footer a[href='/docs']", text: "Docs"
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
