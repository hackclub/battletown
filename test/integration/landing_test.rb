require "test_helper"
require_relative "../support/bosses_helper"

# The landing page is Armand's map (hero, signpost, boss, prizes, FAQ river, last call) with the product behaviours kept.
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
    assert_select ".hero__tagline", /Build projects,\s+get gear/
    assert_select "title", text: "BattleTown"
    assert_select "body.page--landing", 1
    assert_select ".landing[data-controller='landing-map']", 1
  end

  test "headings run h1, then h2 sections with h3 items, never skipping a level" do
    get "/"
    levels = css_select("h1, h2, h3, h4").map { |h| h.name[1].to_i }
    assert_equal 1, levels.first
    assert_equal 1, levels.count(1)
    levels.each_cons(2) { |a, b| assert_operator b - a, :<=, 1, "heading levels jump from h#{a} to h#{b}" }
    [ "How it works", "Fight together", "FAQ" ].each { |text| assert_select "h2", text: text }
    assert_select "h2#prizes-title", text: /Pick a prize\s+to work toward/
    assert_select "h2#final-title", text: /Ready to join\s+the fight\?/
  end

  test "sections run in the map order" do
    get "/"
    classes = css_select(".landing > section").map { |node| node["class"].to_s.split.first }
    assert_equal %w[hero how blk blk blk blk], classes
    assert_equal %w[landing-title how-title boss-title prizes-title faq-title final-title], css_select(".landing > section").map { |node| node["aria-labelledby"] }
  end

  test "how it works is an ordered list of three signs with real text" do
    get "/"
    assert_select "ol.signpost > li.signpost__board", 3
    assert_select ".signpost h3", text: "Build"
    assert_select ".signpost h3", text: "Ship"
    assert_select ".signpost h3", text: "Get your prize"
    assert_select ".signpost__num[aria-hidden='true']", 3
    assert_select ".signpost__board--1 p", text: "Build your project, and count your hours"
    assert_select ".signpost__board--2 p", text: /Ship your project to deal damage to the boss, and get coins/
    assert_select ".signpost__board--3 p", text: /When the boss is defeated, collect your winnings, and claim a prize from the shop/
  end

  test "the sign up button posts to Hack Club Auth with a CSRF token and without Turbo" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get "/"
    assert_select ".hero form[action='/auth/hack_club'][method='post'][data-turbo='false']", 1 do
      assert_select "input[name='authenticity_token'][type='hidden']", 1 do |tokens|
        assert tokens.first["value"].present?
      end
      assert_select "button.cta", text: /Join the fight/
    end
    assert_select ".final form[action='/auth/hack_club'][method='post'][data-turbo='false'] input[name='authenticity_token']", 1
    assert_select ".final button.cta.cta--big", 1
    assert_select ".landing form[action='/auth/hack_club'] button.cta", 2 # hero and last call
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "the call to action only quotes a fighter count once it reaches the threshold" do
    threshold = LandingHelper::FIGHTER_COUNT_THRESHOLD
    assert_operator User.count, :<, threshold
    get "/"
    assert_select "button.cta .cta__label", text: "Join the fight", count: 2
    assert_select "button.cta .cta__label", text: /other fighters/, count: 0

    add_users_until(threshold - 1)
    get "/"
    assert_select "button.cta .cta__label", text: "Join the fight", count: 2

    add_users_until(threshold)
    get "/"
    assert_select "button.cta .cta__label", text: "Join #{threshold} other fighters", count: 2
    assert_select "button.cta .cta__label", text: "Join the fight", count: 0
  end

  test "the boss health is a native progress bar with a text label" do
    get "/"
    assert_select ".fight__health progress.fight__bar[max='100'][aria-labelledby='landing-boss-health'][aria-describedby='landing-boss-label']", 1
    assert_select "#landing-boss-health", text: "Boss health"
    assert_select "#landing-boss-label.fight__label"
    assert_select ".fight__text p", text: /Each boss has a health bar measured in hours of coding\. Everyone who participates contributes hours to defeat the boss/
    assert_select "#final-title", text: /Ready to join/
  end

  test "with no boss this week the bar is full and says the next boss is coming" do
    assert_equal 0, Boss.count
    get "/"
    assert_select ".fight progress[value='100']", text: /next boss is on its way/
    assert_select ".fight__label", text: "Next boss on its way"
  end

  test "the boss bar reads the current boss's aggregate health and nothing about people" do
    today = Hours::Days.today("UTC")
    make_boss(starts_on: today - 1, ends_on: today + 5, hp_seconds: 100 * HOUR)
    user = User.create!(hca_uid: "ident!private", display_name: "Private Person")
    add_hours(user, today, 25 * HOUR)
    get "/"
    assert_select ".fight progress[value='75']"
    assert_select ".fight__label", text: "75 of 100 hours left"
    assert_no_match(/Private Person|ident!private/, response.body)
  end

  test "who's locked in shows a real count only once it is worth showing" do
    get "/"
    assert_select ".final__proof", 0
    add_users_until(LandingHelper::FIGHTER_COUNT_THRESHOLD)
    get "/"
    assert_select ".final__proof", text: /#{LandingHelper::FIGHTER_COUNT_THRESHOLD} fighters are locked in/
  end

  test "keeps the free sticker note" do
    get "/"
    assert_select ".hero__sticker", text: /Free sticker when you sign up/
  end

  test "every image has an alt attribute and decorative ones are empty" do
    get "/"
    images = css_select("img")
    assert_operator images.size, :>=, 8
    images.each { |img| assert img.key?("alt"), "img #{img['src']} has no alt attribute" }
    assert_equal "Battletown", css_select(".hero__logo img").first["alt"]
    assert css_select(".hero__art").first["alt"].present?, "the hero painting should have a description"
    assert css_select(".fight__boss").first["alt"].present?, "the boss is content and needs a description"
    [ ".hero__wash", ".hero__swoosh", ".final__orpheus", ".prize img" ].each do |selector|
      assert_operator css_select(selector).size, :>=, 1, selector
      css_select(selector).each { |img| assert_equal "", img["alt"], "#{selector} is decoration and needs an empty alt" }
    end
  end

  test "the hero painting is served in four widths and only the big one is lazy-free" do
    get "/"
    art = css_select(".hero__art").first
    assert_equal "high", art["fetchpriority"]
    assert_equal "100vw", art["sizes"]
    assert_equal 4, art["srcset"].split(",").size
    assert_match(/ 1280w/, art["srcset"])
    assert_match(/ 3840w/, art["srcset"])
    css_select(".fight__boss, .final__orpheus, .prize img").each { |img| assert_equal "lazy", img["loading"], img["src"] }
  end

  test "landing assets resolve to same-origin digested files that are served" do
    get "/"
    assert_select "link[rel=stylesheet][href^='/assets/fonts-']", 1
    sources = css_select("img").map { |img| img["src"] } + css_select("img[srcset]").flat_map { |img| img["srcset"].split(",").map { |s| s.strip.split.first } }
    assert_operator sources.size, :>=, 8
    sources.uniq.each do |src|
      assert src.start_with?("/assets/"), "#{src} should be a same-origin asset"
      get src
      assert_response :success, src
    end
  end

  test "every landing image file is used by the page or the helper" do
    root = Rails.root.join("app/assets/images/landing")
    source = [ "app/views/landing", "app/helpers/landing_helper.rb", "app/assets/stylesheets/landing.css" ].flat_map { |path| Dir[Rails.root.join(path, "**/*").to_s] + [ Rails.root.join(path).to_s ] }
                .select { |path| File.file?(path) }.map { |path| File.read(path) }.join("\n")
    Dir[root.join("**/*.{svg,webp}").to_s].each do |file|
      relative = Pathname(file).relative_path_from(root).to_s
      stem = relative.sub(/-\d+(?=\.webp)/, "")
      next if relative.start_with?("prizes/") # Armand's photos wait for the final lineup (LandingHelper::PRIZE_ART)

      assert source.include?(relative) || source.include?(stem) || source.include?("landing/#{File.basename(relative, '.*').sub(/-\d+\z/, '')}"), "#{relative} is not referenced"
    end
    LandingHelper::PRIZE_ART.each_value { |path| assert Rails.root.join("app/assets/images", path).exist?, path }
  end

  test "lists every catalogue prize priced in hours" do
    get "/"
    assert_select ".prize", Prize.paid.size
    assert_select ".prize__hours", text: "2 hours"
    assert_select ".prize h3", text: "Battletown T-shirt"
    assert_select ".prize h3", text: Prize.free_signup.name, count: 0
    Prize.paid.each { |prize| assert_select ".prize .prize__hours", text: prize.hours_text, minimum: 1 }
    assert_select ".prize img[src*='keychron-k2']", 1 # the one photo that matches a catalogue prize (the keyboard)
  end

  test "the stylesheet and controller carry the motion and focus rules" do
    css = Rails.root.join("app/assets/stylesheets/landing.css").read
    assert_match(/prefers-reduced-motion: no-preference/, css)
    assert_match(/:focus-visible/, css)
    assert Rails.root.join("app/javascript/controllers/landing_map_controller.js").exist?
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
    assert_select "a.cta[href='#{onboarding_path}'] .cta__label", text: "Continue setup", count: 2
    assert_select ".hero form[action='/auth/hack_club']", 0
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
