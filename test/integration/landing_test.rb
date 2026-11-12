require "test_helper"

class LandingTest < ActionDispatch::IntegrationTest
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

  test "every image has an alt attribute and decorative ones are empty" do
    get "/"
    images = css_select("img")
    assert_operator images.size, :>=, 4
    images.each { |img| assert img.key?("alt"), "img #{img['src']} has no alt attribute" }
    assert_equal "Battletown", css_select(".landing-hero__logo img").first["alt"]
    assert css_select(".landing-hero__art").first["alt"].present?, "the hero painting should have a description"
    assert_equal "", css_select(".landing-hero__swoosh").first["alt"]
    assert_equal "", css_select(".landing-hero__wash").first["alt"]
  end

  test "landing assets resolve to same-origin digested files" do
    get "/"
    css_select("img").each do |img|
      assert img["src"].start_with?("/assets/"), "#{img['src']} should be a same-origin asset"
    end
    assert_select "link[rel=stylesheet][href^='/assets/fonts-']", 1
  end

  test "lists every prize priced in hours" do
    get "/"
    assert_select ".landing-prize", Prize.paid.size
    assert_select ".landing-prize__price", text: "2 hours"
    assert_select ".landing-prize__name", text: "Battletown T-shirt"
  end

  test "pages carry no inline style attributes" do
    get "/"
    assert_select "[style]", 0
  end

  test "shows a referral banner only for a known slug" do
    get "/"
    assert_select ".landing-referral", 0

    get "/haven"
    follow_redirect!
    assert_select ".landing-referral", /Welcome from Haven/

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
    assert_select ".landing-hero form[action='/auth/hack_club']", 0
  end

  test "onboarded users are redirected to the dashboard" do
    sign_in_as users(:onboarded)
    get "/"
    assert_redirected_to dashboard_path
  end
end
