require "test_helper"
require_relative "../support/bosses_helper"

class LandingTest < ActionDispatch::IntegrationTest
  include BossesHelper

  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def add_users_until(total)
    (User.count...total).each { |i| User.create!(hca_uid: "ident!fighter#{i}", display_name: "Fighter #{i}") }
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  test "renders for signed-out visitors with the logo as the page heading" do
    get "/"
    assert_response :success
    assert_select "h1 img[alt='Battletown']", 1
    assert_select ".landing-hero__tagline", /Build projects,\s+get gear/
    assert_select "title", text: "BattleTown"
  end

  test "headings run h1, then h2 sections with h3 items, never skipping a level" do
    get "/"
    levels = css_select("h1, h2, h3, h4").map { |h| h.name[1].to_i }
    assert_equal 1, levels.first
    assert_equal 1, levels.count(1)
    levels.each_cons(2) { |a, b| assert_operator b - a, :<=, 1, "heading levels jump from h#{a} to h#{b}" }
    [ "How it works", "Fight together", "Pick a prize to work toward", "FAQ" ].each { |text| assert_select "h2", text: text }
  end

  test "how it works is an ordered list of three signs with real text" do
    get "/"
    assert_select "ol.signs > li.sign", 3
    assert_select ".sign__title", text: "Build"
    assert_select ".sign__title", text: "Ship"
    assert_select ".sign__title", text: "Get your prize"
    assert_select ".sign__num[aria-hidden='true']", 3
    assert_select ".sign__body", text: /Build your project, and count your hours/
    assert_select ".sign--ship .sign__body", text: /Ship your project to deal damage to the boss,\s+and get coins/
    assert_select ".sign--prize .sign__body", text: /When the boss is defeated, collect your\s+winnings, and claim a prize from the shop/
  end

  test "sections run in the Figma order: hero, signs, map, then the cream band" do
    get "/"
    classes = css_select(".landing > *").map { |node| node["class"].to_s.split.first }
    assert_equal %w[landing-hero landing-signs landing-map band], classes
    assert_select "body.page--landing", 1
  end

  test "the sign up button posts to Hack Club Auth with a CSRF token and without Turbo" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get "/"
    assert_select ".landing-hero form[action='/auth/hack_club'][method='post'][data-turbo='false']", 1 do
      assert_select "input[name='authenticity_token'][type='hidden']", 1 do |tokens|
        assert tokens.first["value"].present?
      end
      assert_select "button.cta", text: /Join the fight/
    end
    assert_select ".landing-map form[action='/auth/hack_club'][method='post'][data-turbo='false'] input[name='authenticity_token']", 1
    assert_select ".landing-map button.cta.cta--bare", 1
    assert_select "form[action='/auth/hack_club'] button.cta", minimum: 2 # hero and closing call to action
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "the call to action only quotes a fighter count once it reaches the threshold" do
    threshold = LandingHelper::FIGHTER_COUNT_THRESHOLD
    assert_operator User.count, :<, threshold
    get "/"
    assert_select "button.cta .cta__label", text: "Join the fight", minimum: 1
    assert_select "button.cta .cta__label", text: /other fighters/, count: 0

    add_users_until(threshold - 1)
    get "/"
    assert_select "button.cta .cta__label", text: "Join the fight", minimum: 1

    add_users_until(threshold)
    get "/"
    assert_select "button.cta .cta__label", text: "Join #{threshold} other fighters", minimum: 1
    assert_select "button.cta .cta__label", text: "Join the fight", count: 0
  end

  test "the map shows the boss health as a native progress bar with a text label" do
    get "/"
    assert_select ".landing-boss__bar progress[max='100'][aria-labelledby='landing-boss-health'][aria-describedby='landing-boss-label']", 1
    assert_select "#landing-boss-health", text: "Boss health"
    assert_select "#landing-boss-label.landing-boss__label"
    assert_select ".landing-map__ready", text: "Ready to join the fight?" # a cream pill (see landing.css), not text straight on the map blue
    assert_select ".landing-map__ready", text: /container/, count: 0
  end

  test "the map copy is the Figma copy with the missing space after the period fixed" do
    get "/"
    assert_select ".landing-map__title", text: "Fight together"
    assert_select ".landing-map__lead", text: /Each boss has a health bar\s+measured in hours of coding\. Everyone who participates contributes hours to defeat the boss/
  end

  test "the map is decorated with twelve trees and seven houses that screen readers skip" do
    get "/"
    assert_select ".landing-map__decor[aria-hidden='true']" do
      assert_select ".landing-tree", 12
      assert_select ".landing-house", 7
    end
  end

  test "with no boss this week the bar is full and says the next boss is coming" do
    assert_equal 0, Boss.count
    get "/"
    assert_select ".landing-map progress[value='100']", text: /next boss is on its way/
    assert_select ".landing-boss__label", text: "Next boss on its way"
  end

  test "the boss bar reads the current boss's aggregate health and nothing about people" do
    today = Hours::Days.today("UTC")
    make_boss(starts_on: today - 1, ends_on: today + 5, hp_seconds: 100 * HOUR)
    user = User.create!(hca_uid: "ident!private", display_name: "Private Person")
    add_hours(user, today, 25 * HOUR)
    get "/"
    assert_select ".landing-map progress[value='75']"
    assert_select ".landing-boss__label", text: "75 of 100 hours left"
    assert_no_match(/Private Person|ident!private/, response.body)
  end

  test "who's locked in shows a real count only once it is worth showing" do
    get "/"
    assert_select "#proof-title", text: "Who's locked in"
    assert_select ".landing-proof", text: /will show up here once Battletown launches/
    add_users_until(LandingHelper::FIGHTER_COUNT_THRESHOLD)
    get "/"
    assert_select ".landing-proof", text: /#{LandingHelper::FIGHTER_COUNT_THRESHOLD} fighters are locked in/
  end

  test "keeps the free sticker note" do
    get "/"
    assert_select ".landing-hero__sticker", text: /Free sticker when you sign up/
  end

  test "every image has an alt attribute and decorative ones are empty" do
    get "/"
    images = css_select("img")
    assert_operator images.size, :>=, 12
    images.each { |img| assert img.key?("alt"), "img #{img['src']} has no alt attribute" }
    assert_equal "Battletown", css_select(".landing-hero__logo img").first["alt"]
    assert css_select(".landing-hero__art").first["alt"].present?, "the hero painting should have a description"
    assert css_select(".landing-boss__art").first["alt"].present?, "the boss is content and needs a description"
    %w[.landing-hero__overlay .sign__art .landing-signs__pole .landing-map__bg .landing-map__river .landing-boss__shadow .landing-map__hero].each do |selector|
      assert_operator css_select(selector).size, :>=, 1, selector
      css_select(selector).each { |img| assert_equal "", img["alt"], "#{selector} is decoration and needs an empty alt" }
    end
  end

  test "landing assets resolve to same-origin digested files that are served" do
    get "/"
    assert_select "link[rel=stylesheet][href^='/assets/fonts-']", 1
    sources = css_select("img").map { |img| img["src"] }
    assert_operator sources.size, :>=, 8
    sources.uniq.each do |src|
      assert src.start_with?("/assets/"), "#{src} should be a same-origin asset"
      get src
      assert_response :success, src
    end
  end

  test "lists every prize priced in hours" do
    get "/"
    assert_select ".landing-prize", Prize.paid.size
    assert_select ".landing-prize__price", text: "2 hours"
    assert_select ".landing-prize__name", text: "Battletown T-shirt"
  end

  test "pages carry no inline style attributes or inline scripts" do
    get "/"
    assert_select "[style]", 0
    assert_select "script:not([src]):not([nonce])", 0 # only the importmap and its loader, which carry the CSP nonce
  end

  test "shows a referral banner only for a known slug" do
    get "/"
    assert_select ".landing-referral", 0

    get "/haven"
    follow_redirect!
    assert_select ".landing-referral[role='status']", /Welcome from Haven/

    reset!
    get "/not-a-real-slug"
    assert_response :not_found
    get "/"
    assert_select ".landing-referral", 0
  end

  test "signed-in users who haven't onboarded are offered to continue setup" do
    sign_in_as users(:new_user)
    get "/"
    assert_response :success
    assert_select "a.cta[href='#{onboarding_path}'] .cta__label", text: "Continue setup", minimum: 1
    assert_select ".landing-map a.cta.cta--bare[href='#{onboarding_path}']", 1
    assert_select ".landing-hero form[action='/auth/hack_club']", 0
  end

  test "the header on the landing is only the account control: the logo is part of the hero" do
    get "/"
    assert_select ".site-header .site-header__brand .visually-hidden", text: "Battletown" # hidden by landing.css, still the home link
    assert_select ".site-header__account form[action='/auth/hack_club'] button", text: "Sign in"
    assert_select ".site-nav, .site-header__nav", 0
  end

  test "onboarded users are redirected to the dashboard" do
    sign_in_as users(:onboarded)
    get "/"
    assert_redirected_to dashboard_path
  end
end
