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
    assert_select "select#user_referral_source", 0
    step("account", referral_source: "terra")
    assert_equal "haven", user.reload.referral_source
  end

  test "the account step describes Hackatime as optional now, not as coming soon" do
    users(:new_user).update!(onboarding_step: 3)
    sign_in_as users(:new_user)

    get onboarding_step_path("account")
    assert_response :success
    assert_no_match(/coming soon/i, response.body)
    assert_select "h2", "Hackatime"
    assert_select "p", /Connecting Hackatime is optional/
  end

  test "unknown referral sources are rejected" do
    user = users(:new_user)
    user.update!(onboarding_step: 3)
    sign_in_as user

    step("account", referral_source: "evilcorp")
    assert_response :unprocessable_content
    assert_nil user.reload.referral_source
  end

  test "the account step offers a normal how-did-you-hear list, optional and in order" do
    user = users(:new_user)
    user.update!(onboarding_step: 3)
    sign_in_as user

    get onboarding_step_path("account")
    assert_response :success
    assert_select "select#user_referral_source option[value='']", "Skip"
    labels = css_select("select#user_referral_source option").map(&:text)
    assert_equal [ "Skip", "Hack Club Slack or community", "A friend or family member", "A teacher or club leader",
                   "Google or another search engine", "YouTube", "TikTok", "Instagram", "Reddit", "Discord",
                   "X / Twitter", "GitHub", "Haven", "Stardance", "Terra", "Something else" ], labels
    assert_select "select#user_referral_source optgroup[label='Hack Club programs'] option", 3
    assert_select "select#user_referral_source > option:last-child", "Something else"
  end

  test "every generic referral source key can be saved" do
    ReferralSource.keys.each do |key|
      user = User.create!(hca_uid: "ident!ref-#{key}", onboarding_step: 3)
      sign_in_as user
      step("account", referral_source: key)
      assert_redirected_to onboarding_step_path("celebrate"), key
      assert_equal key, user.reload.referral_source
    end
  end

  test "skipping the referral question is fine" do
    user = users(:new_user)
    user.update!(onboarding_step: 3)
    sign_in_as user

    step("account", referral_source: "")
    assert_redirected_to onboarding_step_path("celebrate")
    assert_nil user.reload.referral_source
  end

  test "an unknown referral source gets the friendly error" do
    user = users(:new_user)
    user.update!(onboarding_step: 3)
    sign_in_as user

    step("account", referral_source: "bing_ads")
    assert_response :unprocessable_content
    assert_select "[role=alert]", /How you found us/
    assert_nil user.reload.referral_source
  end

  test "a generic referral source is summarised instead of the select" do
    user = users(:new_user)
    user.update!(referral_source: "search", onboarding_step: 3)
    sign_in_as user

    get onboarding_step_path("account")
    assert_select "select#user_referral_source", 0
    assert_select "p", /You told us: Google or another search engine/
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

  test "the zone chosen while onboarding sets the sign-up date, and re-saving the schedule later never moves it" do
    user = users(:new_user) # created at midnight UTC on 1 January: still 31 December in International Date Line West
    sign_in_as user
    finish_through(user, "project")
    step("schedule", coding_day_names: %w[monday], coding_time: "18:30", time_zone: "International Date Line West")
    assert_equal Date.new(2025, 12, 31), Hours::Days.first_counted_date(user.reload)

    step("account")
    step("celebrate")
    assert user.reload.onboarded?
    step("schedule", coding_day_names: %w[monday], coding_time: "18:30", time_zone: "UTC")
    assert_equal "UTC", user.reload.time_zone
    assert_equal Date.new(2025, 12, 31), Hours::Days.first_counted_date(user)
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

  test "the celebration offers a sound toggle that starts on" do
    sign_in_as users(:new_user)
    users(:new_user).update!(onboarding_step: 4)
    get onboarding_step_path("celebrate")
    assert_response :success

    assert_select "[data-controller=onboarding-celebration]" do
      assert_select "[data-onboarding-celebration-target=confetti]"
      assert_select "button[type=button][aria-pressed=true][data-onboarding-celebration-target=sound][data-action='onboarding-celebration#toggleSound']", text: /Sound\s+on/
    end
  end

  test "the celebration loads no external media and the importmap stays same-origin" do
    sign_in_as users(:new_user)
    users(:new_user).update!(onboarding_step: 4)
    get onboarding_step_path("celebrate")

    assert_select "audio, video, source, embed, object, iframe", 0
    css_select("script[src]").each { |script| assert_no_match %r{\A(https?:)?//}, script["src"] }

    importmap = JSON.parse(css_select("script[type=importmap]").first.text)
    assert_includes importmap["imports"], "controllers/onboarding_celebration_controller"
    importmap["imports"].each_value { |path| assert path.start_with?("/"), "#{path} is not same-origin" }
  end

  # -- restyle: progress semantics, labels, error summaries --------------------------------------------

  test "every step says which step it is, in words and in a native progress bar" do
    user = users(:new_user)
    user.update!(onboarding_step: 4)
    sign_in_as user

    OnboardingsController::STEPS.each_with_index do |name, index|
      get onboarding_step_path(name)
      assert_response :success
      assert_select "nav[aria-label='Onboarding progress']" do
        assert_select "#onboarding-progress-label", /Step #{index + 1} of 5/
        assert_select "progress.progress__bar[max='5'][value='#{index + 1}'][aria-labelledby='onboarding-progress-label']"
        assert_select "ol li", 5
        assert_select "[aria-current=step]", 1
      end
      assert_select "h1", 1
    end
  end

  test "the prize cards show hours and each radio sits directly before its card body" do
    sign_in_as users(:new_user)
    get onboarding_step_path("prize")

    assert_select "fieldset legend", "Prize"
    assert_select "label.choice", Prize.paid.size
    Prize.paid.each do |prize|
      assert_select "input.choice__input[type=radio][name='user[prize_key]'][value='#{prize.key}'] + .choice__body", /#{Regexp.escape(prize.hours_text)}/
    end
  end

  test "the form fields have visible labels" do
    user = users(:new_user)
    user.update!(onboarding_step: 3)
    sign_in_as user

    get onboarding_step_path("project")
    assert_select "legend", "What kind of project?"
    assert_select "label[for=user_project_idea]", /Got an idea/
    assert_select "textarea#user_project_idea[aria-describedby=project-idea-count]"
    assert_select "#project-idea-count", /0\/500/
    assert_select ".toggle input.toggle__input[type=radio][name='user[project_kind]']", OnboardingsHelper::PROJECT_KINDS.size

    get onboarding_step_path("schedule")
    assert_select "legend", "Which days do you want to code?"
    assert_select "label[for=user_coding_time]", "What time works best?"
    assert_select ".days .toggle input[type=checkbox][name='user[coding_day_names][]']", 7
    assert_select ".days button.day-all", "Every day"

    get onboarding_step_path("account")
    assert_select "label[for=user_referral_source]", /How did you hear about us/
  end

  test "an invalid step shows a summary that links to the field, and marks the field invalid" do
    user = users(:new_user)
    user.update!(onboarding_step: 2)
    sign_in_as user

    step("schedule", coding_day_names: %w[monday], coding_time: "18:00", time_zone: "Mars/Olympus")
    assert_response :unprocessable_content
    assert_select ".onboarding__errors[role=alert][tabindex='-1'][data-onboarding-step-target=errors]" do
      assert_select "a[href='#user_time_zone']", /Time zone/
    end
    assert_select "select#user_time_zone[aria-invalid=true][aria-describedby=user_time_zone-error]"
    assert_select "#user_time_zone-error.field__error", /Time zone/

    step("schedule", coding_time: "18:00", time_zone: "UTC")
    assert_select ".onboarding__errors a[href='#user_day_monday']", /Days/
    assert_select "fieldset[aria-describedby=days-error] #days-error"
  end

  test "a missing prize or project type is reported against the first option" do
    user = users(:new_user)
    sign_in_as user
    step("prize")
    assert_select ".onboarding__errors a[href='#user_prize_key_#{Prize.paid.first.key}']", /Prize can't be blank/
    assert_select "#user_prize_key_#{Prize.paid.first.key}"

    finish_through(user, "prize")
    step("project")
    assert_select ".onboarding__errors a[href='#user_project_kind_game']", /Project type can't be blank/
    assert_select "#user_project_kind_game"
  end

  test "radios stay directly beside their card after a failed submit" do
    sign_in_as users(:new_user)
    step("prize")
    assert_select ".field_with_errors", 0
    assert_select "input.choice__input + .choice__body", Prize.paid.size
  end

  test "the account step shows a status pill and, once onboarded, links to the Hackatime page" do
    user = users(:new_user)
    user.update!(onboarding_step: 3, verification_status: "needs_submission")
    sign_in_as user

    get onboarding_step_path("account")
    assert_select ".check .badge", "Not verified yet"
    assert_select "a[href='https://auth.hackclub.com'][target=_blank][rel~=noopener]", "Verify with Hack Club"
    assert_select "a[href='#{hackatime_path}']", 0
    assert_select "p", /Connecting Hackatime is optional/

    user.update!(onboarded_at: Time.current, verification_status: "verified")
    get onboarding_step_path("account")
    assert_select ".check .badge", "Verified"
    assert_select "a[href='https://auth.hackclub.com']", 0
    assert_select "p a[href='#{hackatime_path}']"
  end

  test "the schedule step explains when Slack is not linked" do
    user = users(:new_user)
    user.update!(onboarding_step: 2, slack_id: nil)
    sign_in_as user
    get onboarding_step_path("schedule")
    assert_select "[role=note]", /isn't linked to a Slack account/

    user.update!(slack_id: "U123TEST")
    get onboarding_step_path("schedule")
    assert_select "[role=note]", 0
  end

  test "the celebration summarises the plan, says Every day for all seven and keeps the controls" do
    user = users(:new_user)
    user.update!(onboarding_step: 4, prize_key: "tshirt", project_kind: "game", coding_days: 127, coding_time: "18:30", time_zone: "UTC")
    sign_in_as user
    get onboarding_step_path("celebrate")

    assert_select "dl.celebration__summary" do
      assert_select "dd", /Battletown T-shirt/
      assert_select "dd", "Game"
      assert_select "dd", /Every day at 18:30, UTC/
    end
    assert_select ".onboarding-prize", 0
    assert_select "button.celebration__sound[aria-pressed=true]", /Sound\s+on/
    assert_select "form[action='#{onboarding_step_path("celebrate")}'] button", "Enter Battletown"
  end
end
