require "test_helper"

class OnboardingTest < ActionDispatch::IntegrationTest
  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def step(name, params = {})
    patch onboarding_step_path(name), params: { user: params }
  end

  def finish_through(user, last)
    steps = {
      "prize" => { prize_key: "tshirt" },
      "project" => { project_kind: "game", project_idea: "A farming game" },
      "schedule" => { coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC" },
      "account" => {}
    }
    steps.each { |name, params| step(name, params); break if name == last }
    user.reload
  end

  test "requires login" do
    get onboarding_path
    assert_redirected_to root_path
    get onboarding_step_path("prize")
    assert_redirected_to root_path
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
    assert_redirected_to root_path
  end

  test "unknown steps are not routable" do
    sign_in_as users(:new_user)
    get "/onboarding/nope"
    assert_response :not_found
  end

  test "index sends users to their furthest unlocked step" do
    sign_in_as users(:new_user)
    get onboarding_path
    assert_redirected_to onboarding_step_path("prize")
    users(:new_user).update!(onboarding_step: 2)
    get onboarding_path
    assert_redirected_to onboarding_step_path("schedule")
  end

  test "full happy path completes onboarding" do
    user = users(:new_user)
    sign_in_as user

    get onboarding_step_path("prize")
    assert_response :success
    assert_select "[aria-current=step]", /Prize/

    step("prize", prize_key: "tshirt")
    assert_redirected_to onboarding_step_path("project")
    follow_redirect!
    assert_select ".onboarding-prize", /Battletown T-shirt/

    step("project", project_kind: "game", project_idea: "A farming game")
    assert_redirected_to onboarding_step_path("schedule")

    step("schedule", coding_day_names: %w[monday wednesday], coding_time: "18:30", time_zone: "UTC")
    assert_redirected_to onboarding_step_path("account")

    step("account", referral_source: "terra")
    assert_redirected_to onboarding_step_path("celebrate")

    user.reload
    assert_equal "tshirt", user.prize_key
    assert_equal "game", user.project_kind
    assert_equal 5, user.coding_days
    assert_equal "terra", user.referral_source
    assert_equal 4, user.onboarding_step
    assert_not user.onboarded?

    get onboarding_step_path("celebrate")
    assert_response :success
    step("celebrate")
    assert_redirected_to dashboard_path
    assert user.reload.onboarded?
  end

  test "bad values are rejected and nothing advances" do
    user = users(:new_user)
    sign_in_as user

    step("prize", prize_key: "nope")
    assert_response :unprocessable_content
    step("prize")
    assert_response :unprocessable_content
    assert_equal 0, user.reload.onboarding_step
    assert_nil user.prize_key

    finish_through(user, "prize")
    step("project", project_kind: "spaceship")
    assert_response :unprocessable_content
    step("project", project_kind: "game", project_idea: "x" * 501)
    assert_response :unprocessable_content
    assert_equal 1, user.reload.onboarding_step

    finish_through(user, "project")
    step("schedule", coding_day_names: %w[monday], coding_time: "25:99", time_zone: "UTC")
    assert_response :unprocessable_content
    step("schedule", coding_day_names: %w[monday], coding_time: "18:00", time_zone: "Mars/Olympus")
    assert_response :unprocessable_content
    step("schedule", coding_day_names: %w[funday], coding_time: "18:00", time_zone: "UTC")
    assert_response :unprocessable_content
    assert_equal 2, user.reload.onboarding_step
  end

  test "cannot skip ahead" do
    user = users(:new_user)
    sign_in_as user

    get onboarding_step_path("schedule")
    assert_redirected_to onboarding_step_path("prize")
    step("celebrate")
    assert_redirected_to onboarding_step_path("prize")
    assert_not user.reload.onboarded?
    step("account", referral_source: "haven")
    assert_redirected_to onboarding_step_path("prize")
    assert_nil user.reload.referral_source
  end

  test "an existing referral source is never overwritten" do
    user = users(:new_user)
    user.update!(referral_source: "haven", onboarding_step: 3)
    sign_in_as user

    get onboarding_step_path("account")
    assert_select "p", /You came from Haven/
    step("account", referral_source: "terra")
    assert_equal "haven", user.reload.referral_source
  end

  test "unknown referral sources are rejected" do
    user = users(:new_user)
    user.update!(onboarding_step: 3)
    sign_in_as user

    step("account", referral_source: "evilcorp")
    assert_response :unprocessable_content
    assert_nil user.reload.referral_source
  end

  test "completion is idempotent" do
    user = users(:new_user)
    user.update!(onboarding_step: 4)
    sign_in_as user

    step("celebrate")
    first = user.reload.onboarded_at
    assert first
    step("celebrate")
    assert_redirected_to dashboard_path
    assert_equal first, user.reload.onboarded_at
  end

  test "onboarded users skip the celebration but can edit earlier steps" do
    user = users(:onboarded)
    sign_in_as user

    get onboarding_path
    assert_redirected_to onboarding_step_path("prize")
    get onboarding_step_path("celebrate")
    assert_redirected_to dashboard_path

    step("prize", prize_key: "sticker_pack")
    assert_redirected_to dashboard_path
    assert_equal "sticker_pack", user.reload.prize_key
    assert_equal 4, user.onboarding_step
  end

  test "no prize is preselected for a new user" do
    sign_in_as users(:new_user)
    get onboarding_step_path("prize")
    assert_select "input[type=radio][checked]", 0
  end

  test "user ids in params are ignored" do
    user = users(:new_user)
    sign_in_as user
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt", id: users(:onboarded).id, onboarded_at: Time.current } }
    assert_not user.reload.onboarded?
    assert_equal "tshirt", user.prize_key
    assert_equal "tshirt", users(:onboarded).reload.prize_key
  end

  test "a scalar or malformed user param is rejected cleanly instead of raising" do
    user = users(:new_user)
    sign_in_as user
    patch onboarding_step_path("prize"), params: { user: "abc" }
    assert_response :unprocessable_content
    patch onboarding_step_path("prize"), params: { user: [ "abc" ] }
    assert_response :unprocessable_content
    assert_nil user.reload.prize_key
  end
end
