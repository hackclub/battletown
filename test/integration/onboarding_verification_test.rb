require "test_helper"

# The rule: sign-in reads the person's Hack Club Auth verification status and stores it silently. Nobody is asked about it
# while onboarding or shipping; the only prompt is when they try to spend coins in the shop (see shop_test and
# eligibility_gate_test, which this file does not change).
class OnboardingVerificationTest < ActionDispatch::IntegrationTest
  STATUSES = %w[needs_submission pending verified ineligible].freeze
  SIGNED_IN_STEPS = %w[prize project schedule account celebrate].freeze

  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_with(uid, raw_info = {})
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: uid, extra: { raw_info: raw_info })
    post "/auth/hack_club"
    follow_redirect!
  end

  test "the account step has no verification card, badge or link whatever the status" do
    STATUSES.each do |status|
      user = users(:new_user)
      user.update!(onboarding_step: 5, verification_status: status, onboarded_at: nil)
      sign_in_with(user.hca_uid, "verification_status" => status)

      get onboarding_step_path("account")
      assert_response :success, status
      assert_select "h2", text: /verif/i, count: 0
      assert_select ".check .badge", text: /verif|eligible|in review/i, count: 0
      assert_select "a[href='https://auth.hackclub.com']", 0
      assert_no_match(/verif|identity/i, css_select("main").text, status)
      assert_select "h2", "Hackatime"
      assert_select "label[for=user_referral_source]", /How did you hear about us/
    end
  end

  test "the account step asks for Hackatime in plain words and points at no header menu that is not there yet" do
    user = users(:new_user)
    user.update!(onboarding_step: 5)
    sign_in_with(user.hca_uid)

    get onboarding_step_path("account")
    assert_select "nav .site-menu", 0
    assert_select "#hackatime-check p", /how your hours count/
  end

  test "every onboarding step a signed-in person sees is free of verification prompts" do
    STATUSES.each do |status|
      user = users(:new_user)
      user.update!(onboarding_step: OnboardingsController::STEPS.index("celebrate"), verification_status: status, onboarded_at: nil)
      sign_in_with(user.hca_uid, "verification_status" => status)
      # (the account step needs Hackatime, so someone at the last step has it)
      HackatimeConnection.create!(user: user, hackatime_uid: "8181", access_token: "t" * 20, scopes: "profile read", connected_at: Time.current) if user.hackatime_connection.nil?

      SIGNED_IN_STEPS.each do |name|
        get onboarding_step_path(name)
        assert_response :success, "#{status} #{name}"
        assert_no_match(/verif|identity/i, css_select("main").text, "#{status} #{name}")
      end
    end
  end

  test "the sign-up step does not mention verification" do
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
    patch onboarding_step_path("project"), params: { user: { project_kind: "game", project_idea: "A farming game" } }
    patch onboarding_step_path("schedule"), params: { user: { coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC" } }

    get onboarding_step_path("signup")
    assert_response :success
    assert_select ".checks p", "Signing in with Hack Club takes a few seconds and gets you a free sticker."
    assert_select "button", "Sign up with Hack Club"
    assert_no_match(/verif|identity/i, css_select("main").text)
  end

  test "the landing FAQ no longer says to verify before shipping" do
    get root_path
    assert_response :success
    assert_select ".faq details summary", "Who can join?"
    assert_select ".faq details p", "Any teen aged 13 to 18. You sign in with your Hack Club account."
    assert_select ".faq", text: /verify your identity/i, count: 0
  end

  test "sign-in stores the verification status and eligibility from the Hack Club Auth claims" do
    STATUSES.each_with_index do |status, index|
      uid = "ident!status#{index}"
      freeze_time do
        sign_in_with(uid, "verification_status" => status, "ysws_eligible" => status != "ineligible")

        user = User.find_by!(hca_uid: uid)
        assert_equal status, user.verification_status
        assert_equal status != "ineligible", user.ysws_eligible
        assert_equal Time.current, user.verification_checked_at
      end
    end
  end

  test "a later sign-in refreshes the stored status, and a claim we do not know leaves it alone" do
    uid = "ident!refresh"
    sign_in_with(uid, "verification_status" => "needs_submission", "ysws_eligible" => false)
    user = User.find_by!(hca_uid: uid)
    assert_predicate user, :verification_needs_submission?
    assert_not user.ysws_eligible

    delete logout_path
    travel 2.days do
      sign_in_with(uid, "verification_status" => "verified", "ysws_eligible" => true)
      user.reload
      assert_predicate user, :verification_verified?
      assert user.ysws_eligible
      assert_in_delta Time.current, user.verification_checked_at, 5.seconds
    end

    delete logout_path
    sign_in_with(uid, "verification_status" => "something_new", "ysws_eligible" => true)
    assert_predicate user.reload, :verification_verified?
  end

  test "signing in never sends anyone to a verification page: a new unverified account goes on to onboarding" do
    sign_in_with("ident!unverified", "verification_status" => "needs_submission")
    assert_redirected_to onboarding_path
    follow_redirect!
    assert_redirected_to onboarding_step_path("prize")
  end
end
