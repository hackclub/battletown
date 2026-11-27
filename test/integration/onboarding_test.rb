require "test_helper"
require_relative "../support/hackatime_helper"

class OnboardingTest < ActionDispatch::IntegrationTest
  include HackatimeHelper
  PRIZE_STEP_FOR_TEST = OnboardingsController::STEPS.index("prize")
  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user)
    # Someone at the last step got there through the account step, which needs a Hackatime connection.
    if user.persisted? && user.onboarding_step >= 6 && !user.onboarded? && user.hackatime_connection.nil?
      connect_hackatime(user, uid: (9000 + user.id).to_s)
    end
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def step(name, params = {})
    walk_quiz_to(name) unless %w[age prize].include?(name)
    connect_hackatime_for_session_user if name == "account"
    patch onboarding_step_path(name), params: { user: params }
  end

  # Hackatime is required to finish the account step, so a test that gets that far has the signed-in person connect first.
  def connect_hackatime_for_session_user
    user = User.find_by(id: session[:user_id])
    connect_hackatime(user, uid: (9000 + user.id).to_s) if user && !user.onboarded? && user.hackatime_connection.nil?
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

  test "unknown steps are not routable" do
    sign_in_as users(:new_user)
    get "/onboarding/nope"
    assert_response :not_found
  end

  test "index sends users to their furthest unlocked step" do
    sign_in_as users(:new_user)
    get onboarding_path
    assert_redirected_to onboarding_step_path("prize")
    users(:new_user).update!(onboarding_step: 3)
    get onboarding_path
    assert_redirected_to onboarding_step_path("schedule")
  end

  test "full happy path completes onboarding" do
    user = users(:new_user)
    sign_in_as user

    get onboarding_step_path("prize")
    assert_response :success
    assert_select "progress.onboarding-top__bar[value='1']" # a signed-in person skips the age screen

    step("prize", prize_key: "tshirt")
    assert_redirected_to onboarding_step_path("use")
    follow_redirect!
    assert_select ".transition--proof", 0 # no others-like-you splash
    assert_select "#onboarding-prize-dock", (Prize.find("tshirt").image.present? ? 1 : 0) # the docked picture, only for a prize that has one

    step("project", project_kind: "game", project_idea: "A farming game")
    assert_redirected_to onboarding_step_path("detail")

    step("schedule", coding_day_names: %w[monday wednesday], coding_time: "18:30", time_zone: "UTC")
    assert_redirected_to onboarding_step_path("pace_date")

    step("account", referral_source: "terra")
    assert_redirected_to onboarding_step_path("celebrate")

    user.reload
    assert_equal "tshirt", user.prize_key
    assert_equal "game", user.project_kind
    assert_equal 5, user.coding_days
    assert_equal "terra", user.referral_source
    assert_equal 6, user.onboarding_step
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
    assert_equal 2, user.reload.onboarding_step

    finish_through(user, "project")
    step("schedule", coding_day_names: %w[monday], coding_time: "25:99", time_zone: "UTC")
    assert_response :unprocessable_content
    step("schedule", coding_day_names: %w[monday], coding_time: "18:00", time_zone: "not a zone")
    assert_response :unprocessable_content
    step("schedule", coding_day_names: %w[funday], coding_time: "18:00", time_zone: "UTC")
    assert_response :unprocessable_content
    assert_equal 3, user.reload.onboarding_step
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
    user.update!(referral_source: "haven", onboarding_step: 5)
    sign_in_as user

    get onboarding_step_path("account")
    assert_select "p", /You came from Haven/
    assert_select "select#user_referral_source", 0
    step("account", referral_source: "terra")
    assert_equal "haven", user.reload.referral_source
  end

  test "unknown referral sources are rejected" do
    user = users(:new_user)
    user.update!(onboarding_step: 5)
    sign_in_as user

    step("account", referral_source: "evilcorp")
    assert_response :unprocessable_content
    assert_nil user.reload.referral_source
  end

  test "the account step offers a normal how-did-you-hear list, optional and in order" do
    user = users(:new_user)
    user.update!(onboarding_step: 5)
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
      user = User.create!(hca_uid: "ident!ref-#{key}", onboarding_step: 5)
      sign_in_as user
      step("account", referral_source: key)
      assert_redirected_to onboarding_step_path("celebrate"), key
      assert_equal key, user.reload.referral_source
    end
  end

  test "skipping the referral question is fine" do
    user = users(:new_user)
    user.update!(onboarding_step: 5)
    sign_in_as user

    step("account", referral_source: "")
    assert_redirected_to onboarding_step_path("celebrate")
    assert_nil user.reload.referral_source
  end

  test "an unknown referral source gets the friendly error" do
    user = users(:new_user)
    user.update!(onboarding_step: 5)
    sign_in_as user

    step("account", referral_source: "bing_ads")
    assert_response :unprocessable_content
    assert_select "[role=alert]", /Pick one of the options in the list/
    assert_nil user.reload.referral_source
  end

  test "a generic referral source is summarised instead of the select" do
    user = users(:new_user)
    user.update!(referral_source: "search", onboarding_step: 5)
    sign_in_as user

    get onboarding_step_path("account")
    assert_select "select#user_referral_source", 0
    assert_select "p", /You told us: Google or another search engine/
  end

  test "completion is idempotent" do
    user = users(:new_user)
    user.update!(onboarding_step: 6)
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
    assert_equal 6, user.onboarding_step
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
    users(:new_user).update!(onboarding_step: 6)
    connect_hackatime(users(:new_user))
    get onboarding_step_path("celebrate")
    assert_response :success

    assert_select "[data-controller=onboarding-celebration]" do
      assert_select "[data-onboarding-celebration-target=confetti]"
      assert_select "button[type=button][aria-pressed=true][data-onboarding-celebration-target=sound][data-action='onboarding-celebration#toggleSound']", text: /Sound\s+on/
    end
  end

  test "the celebration loads no external media and the importmap stays same-origin" do
    sign_in_as users(:new_user)
    users(:new_user).update!(onboarding_step: 6)
    connect_hackatime(users(:new_user))
    get onboarding_step_path("celebrate")

    assert_select "audio, video, source, embed, object, iframe", 0
    css_select("script[src]").each { |script| assert_no_match %r{\A(https?:)?//}, script["src"] }

    importmap = JSON.parse(css_select("script[type=importmap]").first.text)
    assert_includes importmap["imports"], "controllers/onboarding_celebration_controller"
    importmap["imports"].each_value { |path| assert path.start_with?("/"), "#{path} is not same-origin" }
  end

  # -- restyle: progress semantics, labels, error summaries --------------------------------------------

  test "every step shows the quick-progress label and a native progress bar" do
    user = users(:new_user)
    user.update!(onboarding_step: 6)
    sign_in_as user

    %w[prize project schedule account celebrate].each do |name|
      walk_quiz_to(name)
      get onboarding_step_path(name)
      assert_response :success
      assert_select ".onboarding-top #onboarding-progress-label", OnboardingsHelper::STEP_COPY.fetch(name)[:progress]
      assert_select ".onboarding-top progress.onboarding-top__bar[max][value][aria-labelledby='onboarding-progress-label']"
      assert_select "h1", 1
      step(name, { "prize" => { prize_key: "tshirt" }, "project" => { project_kind: "game" }, "schedule" => { coding_day_names: %w[monday], coding_time: "18:30", time_zone: "UTC", pace_minutes: 60 } }.fetch(name, {})) if name != "celebrate"
    end
  end

  test "the prize cards show hours and each radio sits directly before its card body" do
    sign_in_as users(:new_user)
    get onboarding_step_path("prize")

    assert_select "fieldset legend", "Prize"
    assert_select "label.choice", Prize.paid.size
    Prize.paid.each do |prize|
      assert_select "label.choice:has(input.choice__input[type=radio][name='user[prize_key]'][value='#{prize.key}'])", /#{Regexp.escape(prize.hours_text)}/
    end
  end

  test "the form fields have visible labels" do
    user = users(:new_user)
    user.update!(onboarding_step: 5)
    sign_in_as user

    get onboarding_step_path("project")
    assert_select "legend", "What kind of project?"
    assert_select "textarea", 0 # no idea box on the question: every single-choice step is just its options
    assert_select ".choice-grid--rows .choice input.choice__input[type=radio][name='user[project_kind]']", User::OFFERED_PROJECT_KINDS.size
    assert_select ".placeholder-link", 0 # no "coming soon" badges

    get onboarding_step_path("schedule")
    assert_select "legend", "Daily pace"
    assert_select ".choice-grid--rows input[type=radio][name='user[pace_minutes]']", 4

    get onboarding_step_path("account")
    assert_select "label[for=user_referral_source]", /How did you hear about us/
  end

  test "an invalid step shows a summary that links to the field, and marks the field invalid" do
    user = users(:new_user)
    user.update!(onboarding_step: 6, onboarded_at: Time.current) # editing: the full form, which still has the zone picker
    sign_in_as user

    step("schedule", coding_day_names: %w[monday], coding_time: "18:00", time_zone: "not a zone")
    assert_response :unprocessable_content
    assert_select ".onboarding__errors[role=alert][tabindex='-1'][data-onboarding-step-target=errors]" do
      assert_select "a[href='#user_time_zone']", /Choose your time zone from the list/
    end
    assert_select "select#user_time_zone[aria-invalid=true][aria-describedby=user_time_zone-error]"
    assert_select "#user_time_zone-error.field__error", /Choose your time zone from the list/

    step("schedule", coding_time: "18:00", time_zone: "UTC")
    assert_select ".onboarding__errors", /Pick at least one day/ # the first-run form always sends days; the server still refuses none
  end

  test "every single-choice step is native radios that send on their own: no Continue, and the server still validates" do
    user = users(:new_user)
    sign_in_as user
    step("prize")
    assert_response :unprocessable_content # the server still refuses an empty prize
    assert_select "form .choice-grid--cards input[type=radio][name='user[prize_key]']", Prize.paid.count
    assert_select "form button.btn", 0
    assert_select "p#onboarding-lead"

    finish_through(user, "prize")
    walk_quiz_to("project")
    get onboarding_step_path("project")
    assert_select "form .choice-grid--rows input[type=radio][name='user[project_kind]']"
    assert_select "form button.btn", 0

    finish_through(user, "project")
    walk_quiz_to("schedule")
    get onboarding_step_path("schedule")
    assert_select "form .choice-grid--rows input[type=radio][name='user[pace_minutes]']", 4
    assert_select "form button.btn", 0
  end

  test "a missing prize or project type is reported against the first option" do
    user = users(:new_user)
    sign_in_as user
    step("prize")
    assert_select ".onboarding__errors a[href='#user_prize_key_#{Prize.paid.first.key}']", "Pick a prize to continue"
    assert_select "#user_prize_key_#{Prize.paid.first.key}"

    finish_through(user, "prize")
    step("project")
    assert_select ".onboarding__errors a[href='#user_project_kind_game']", "Pick a kind of project"
    assert_select "#user_project_kind_game"
  end

  test "radios stay directly beside their card after a failed submit" do
    sign_in_as users(:new_user)
    step("prize")
    assert_select ".field_with_errors", 0
    assert_select "label.choice input.choice__input", Prize.paid.size
  end

  test "the account step asks for Hackatime, and once onboarded links to the Hackatime page" do
    user = users(:new_user)
    user.update!(onboarding_step: 5)
    sign_in_as user

    get onboarding_step_path("account")
    assert_select "#hackatime-check .badge", "Required"
    assert_select "a[href='#{hackatime_path}']", 0

    connect_hackatime(user)
    user.update!(onboarded_at: Time.current)
    get onboarding_step_path("account")
    assert_select "#hackatime-check .badge", "Connected"
  end

  test "the schedule step explains when Slack is not linked" do
    user = users(:new_user)
    user.update!(onboarding_step: 3, slack_id: nil)
    sign_in_as user
    get onboarding_step_path("schedule")
    assert_select "[role=note]", /isn't linked to a Slack account/

    user.update!(slack_id: "U123TEST")
    get onboarding_step_path("schedule")
    assert_select "[role=note]", 0
  end

  test "the last step keeps the controls and no longer holds the pledge" do
    user = users(:new_user)
    user.update!(onboarding_step: 6, prize_key: "tshirt", project_kind: "game", coding_days: 127, coding_time: "18:30", time_zone: "UTC")
    sign_in_as user
    get onboarding_step_path("celebrate")

    assert_select ".pledge__text", 0
    assert_select "#onboarding-prize-dock", 0
    assert_select "button.celebration__sound[aria-pressed=true]", /Sound\s+on/
    assert_select "form[action='#{onboarding_step_path("celebrate")}'] button", "Enter Battletown"
  end

  test "the first screen after sign-in is the signed pledge, once, before the tracker setup" do
    user = users(:new_user)
    user.update!(onboarding_step: 4, prize_key: "tshirt", project_kind: "game", coding_days: 127, coding_time: "18:30", pace_minutes: 120, time_zone: "UTC")
    sign_in_as user
    get onboarding_path
    follow_redirect!
    assert_select ".pledge__text", /8BitDo Pro 2/
    assert_select ".pledge__signature .pledge__name"
    assert_select ".pledge__day", "Day 1 starts now."
    assert_select "a", "Set up Hackatime"
    get onboarding_step_path("account") # it shows once
    assert_select ".pledge__text", 0
  end

  # -- before sign-in: age gate, session draft, sign-up, social proof ------------------------------------

  def anonymous_through(last)
    steps = [
      [ "age", { age_group: "teen" } ],
      [ "prize", { prize_key: "tshirt" } ],
      [ "project", { project_kind: "game", project_idea: "A farming game" } ],
      [ "schedule", { coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC" } ]
    ]
    steps.each { |name, params| step(name, params); break if name == last }
  end

  test "visitors start onboarding without an account, at the age question" do
    get onboarding_path
    assert_redirected_to onboarding_step_path("age")
    follow_redirect!
    assert_response :success
    assert_select "h1", "How old are you?"
    assert_select ".choice-grid--rows label.choice:has(input[name='user[age_group]'][value=teen])", /teen aged 13–18/
    assert_select ".choice-grid--rows label.choice:has(input[name='user[age_group]'][value=adult])", /not 13–18/
    assert_select "button", text: /Continue/, count: 0 # a pick answers and moves on
  end

  test "onboarding has no site header, no Dev login button and no footer: the strip is the top, with a plain Sign in for visitors" do
    get onboarding_step_path("age")
    assert_select ".site-header", 0
    assert_select "form[action='/dev_login']", 0
    assert_select ".site-footer", 0
    assert_select ".onboarding-page .onboarding-top" do
      assert_select "a.onboarding-top__logo[href='#{root_path}'] img[src*='logo']"
      assert_select ".onboarding-top__side form[action='/auth/hack_club'] button.onboarding-top__signin", "Sign in"
    end
  end

  test "a signed-in person in the flow sees the strip with no Sign in and no site header" do
    sign_in_as users(:new_user)
    get onboarding_step_path("prize")
    assert_select ".site-header", 0
    assert_select ".site-footer", 0
    assert_select ".onboarding-top a.onboarding-top__logo"
    assert_select ".onboarding-top form[action='/auth/hack_club']", 0
  end

  test "the sign-up step links to the terms and the privacy policy, since there is no footer to do it" do
    anonymous_through("schedule")
    walk_quiz_to("signup")
    get onboarding_step_path("signup")
    assert_select ".onboarding__panel a[href='#{terms_path}']", "Terms"
    assert_select ".onboarding__panel a[href='#{privacy_path}']", "Privacy Policy"
  end

  test "the progress bar sits at the top, its numbers are for screen readers only, and there is no back button" do
    get onboarding_step_path("age")
    assert_select ".onboarding-top progress.onboarding-top__bar[max][value='1']"
    assert_select ".onboarding-top .visually-hidden #onboarding-progress-step", /\AStep 1 of \d+\z/
    assert_select ".onboarding-top__back", 0
    assert_select ".onboarding-top__head", 0

    anonymous_through("age")
    get onboarding_step_path("prize")
    assert_select "progress.onboarding-top__bar[value='2']"
    assert_select ".onboarding-top__back", 0
  end

  test "the welcome splash plays once per visit and is left out when signed in" do
    get onboarding_step_path("age")
    assert_select ".transition--welcome[data-turbo-temporary]", /Welcome to/
    assert_select ".transition--welcome img.transition__logo"
    get onboarding_step_path("age")
    assert_select ".transition", 0

    reset!
    sign_in_as users(:new_user)
    get onboarding_step_path("prize")
    assert_select ".transition", 0
  end

  test "someone who is not a teen is told kindly and cannot continue" do
    step("age", age_group: "adult")
    assert_response :unprocessable_content # Turbo only shows form responses that redirect or carry an error status
    assert_select "h1", /just for teens/
    get onboarding_step_path("prize")
    assert_redirected_to onboarding_step_path("age")
    step("age", age_group: "nonsense")
    assert_select "h1", /just for teens/
    patch onboarding_step_path("age"), params: { user: "abc" }
    assert_response :unprocessable_content
    patch onboarding_step_path("age")
    assert_response :unprocessable_content
  end

  test "the Slack-not-linked note is only for signed-in users, never for visitors who have no account yet" do
    anonymous_through("project")
    walk_quiz_to("schedule")
    get onboarding_step_path("schedule")
    assert_response :success
    assert_select "[role=note]", 0
  end

  test "signing in does not erase the schedule an unfinished account already has" do
    user = User.create!(hca_uid: "ident!returning", coding_days: 31, coding_time: "07:15", time_zone: "UTC", onboarding_step: 3)
    anonymous_through("prize")
    sign_in_as user
    user.reload
    assert_equal [ 31, "07:15", "UTC", "tshirt" ], [ user.coding_days, user.coding_time, user.time_zone, user.prize_key ]
  end

  test "a prize archived between picking it and signing in does not break the sign-in" do
    anonymous_through("schedule")
    ShopItem.find_by!(key: "tshirt").update!(active: false)
    Prize.reload!
    assert_nothing_raised { sign_in_as User.new(hca_uid: "ident!late") }
    user = User.find_by!(hca_uid: "ident!late")
    assert_nil user.prize_key
    assert_equal [ "game", "18:30", PRIZE_STEP_FOR_TEST ], [ user.project_kind, user.coding_time, user.onboarding_step ] # the rest is kept
    follow_redirect!
    assert_redirected_to onboarding_step_path("prize") # and they pick another prize, whatever the quiz had reached
  ensure
    ShopItem.find_by(key: "tshirt")&.update!(active: true)
    Prize.reload!
  end

  test "visitors cannot skip ahead or reach the signed-in steps" do
    get onboarding_step_path("schedule")
    assert_redirected_to onboarding_step_path("age")
    anonymous_through("schedule")
    %w[account celebrate].each do |name|
      get onboarding_step_path(name)
      assert_redirected_to onboarding_step_path("pace_date")
    end
    patch onboarding_step_path("celebrate")
    assert_redirected_to onboarding_step_path("pace_date")
  end

  test "bad answers are rejected before sign-in too" do
    step("age", age_group: "teen")
    step("prize", prize_key: "nope")
    assert_response :unprocessable_content
    step("prize", prize_key: "tshirt")
    step("project", project_kind: "spaceship")
    assert_response :unprocessable_content
    step("project", project_kind: "game", project_idea: "x" * 501)
    assert_response :unprocessable_content
    get onboarding_step_path("schedule")
    assert_redirected_to onboarding_step_path("project")
  end

  test "answers live in the session until sign-in: no user is created, the sign-up step summarises them" do
    assert_no_difference [ "User.count", "Project.count" ] do
      anonymous_through("schedule")
    end
    walk_quiz_to("signup")
    get onboarding_step_path("signup")
    assert_response :success
    assert_select ".pledge__text", /8BitDo Pro 2/
    assert_select "form[action='/auth/hack_club'][method=post][data-turbo=false] button", /Hold to sign with Hack Club/
  end

  test "signing in at the end carries the answers onto the new account, creates the first project and goes to the account step" do
    get "/haven"
    anonymous_through("schedule")
    walk_quiz_to("signup")
    sign_in_as User.new(hca_uid: "ident!fresh")
    follow_redirect!
    assert_redirected_to onboarding_step_path("account")

    user = User.find_by!(hca_uid: "ident!fresh")
    assert_equal "tshirt", user.prize_key
    assert_equal "game", user.project_kind
    assert_equal "A farming game", user.project_idea
    assert_equal 17, user.coding_days
    assert_equal "18:30", user.coding_time
    assert_equal "UTC", user.time_zone
    assert_equal "haven", user.referral_source
    assert_equal 5, user.onboarding_step
    assert_not user.onboarded?
    assert_equal [ "game" ], user.projects.map(&:kind)

    step("account", referral_source: "")
    assert_redirected_to onboarding_step_path("celebrate")
    step("celebrate")
    assert_redirected_to dashboard_path
    assert user.reload.onboarded?
  end

  test "someone with an account who signs in mid-onboarding goes to the dashboard and the draft changes nothing" do
    step("age", age_group: "teen")
    step("prize", prize_key: "sticker_pack") # the fixture's own account has tshirt and game
    step("project", project_kind: "website", project_idea: "A different idea")
    onboarded = users(:onboarded)
    before = onboarded.attributes.slice("prize_key", "project_kind", "project_idea", "coding_days", "coding_time", "onboarding_step", "onboarded_at")
    assert_no_difference "Project.count" do
      OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: onboarded.hca_uid, extra: { raw_info: {} })
      post "/auth/hack_club"
      follow_redirect!
    end
    assert_redirected_to dashboard_path
    assert_equal before, onboarded.reload.attributes.slice(*before.keys)
    assert_equal "tshirt", onboarded.prize_key
  end

  test "signing in with nothing answered starts a new account at the prize step" do
    sign_in_as User.new(hca_uid: "ident!newcomer")
    follow_redirect!
    assert_redirected_to onboarding_step_path("prize")
    assert_equal 0, User.find_by!(hca_uid: "ident!newcomer").onboarding_step
  end

  test "signing in part-way keeps the answers so far and resumes after them" do
    anonymous_through("prize")
    sign_in_as User.new(hca_uid: "ident!partway")
    assert_equal "tshirt", User.find_by!(hca_uid: "ident!partway").prize_key
    follow_redirect!
    assert_redirected_to onboarding_step_path("use")
  end

  test "a signed-in user never sees the age or sign-up steps" do
    sign_in_as users(:new_user)
    get onboarding_step_path("age")
    assert_redirected_to onboarding_step_path("prize")
    users(:new_user).update!(onboarding_step: 4)
    walk_quiz_to("signup")
    get onboarding_step_path("signup")
    assert_redirected_to onboarding_step_path("account")
    get onboarding_step_path("account")
    assert_response :success
  end

  test "the prize and project steps lead straight to the next step with no others-like-you splash" do
    anonymous_through("age")
    step("prize", prize_key: "tshirt")
    assert_redirected_to onboarding_step_path("use")
    follow_redirect!
    assert_response :success
    assert_select ".transition--proof", 0
    assert_select "progress.onboarding-top__bar[value='3']"
    assert_select "h1", /What would you do with your/
    step("project", project_kind: "app")
    follow_redirect!
    assert_select ".transition--proof", 0
  end


  test "the transition is only for someone still onboarding, never for editing a finished profile, and does not leak to other steps" do
    sign_in_as users(:onboarded)
    step("prize", prize_key: "sticker_pack")
    assert_redirected_to dashboard_path
    get onboarding_step_path("prize")
    assert_select ".transition", 0

    reset!
    anonymous_through("age")
    step("prize", prize_key: "tshirt")
    get onboarding_step_path("prize") # not the step after the one just saved: the flag is dropped, not shown here
    assert_select ".transition", 0
    get onboarding_step_path("project")
    assert_select ".transition", 0
  end

  test "a project idea made only of whitespace is saved as empty, and unknown formats are a 404" do
    anonymous_through("prize")
    step("project", project_kind: "game", project_idea: "  \n\t ")
    assert_redirected_to onboarding_step_path("detail")
    get onboarding_step_path("project")
    assert_select "textarea", 0
    get "/onboarding/age.json"
    assert_response :not_found
  end

  test "the biggest ideas a visitor can keep fit in the session cookie all the way through sign-up" do
    [ "x" * 500, "😀" * 300 ].each_with_index do |idea, i|
      reset!
      get "/haven" # the session also carries the referral slug
      step("age", age_group: "teen")
      step("prize", prize_key: "tshirt")
      step("project", project_kind: "game", project_idea: idea)
      assert_redirected_to onboarding_step_path("detail"), "idea #{i}"
      step("schedule", coding_day_names: User::DAYS, coding_time: "18:30", time_zone: "UTC")
      assert_redirected_to onboarding_step_path("pace_date")
      sign_in_as User.new(hca_uid: "ident!big#{i}")
      assert_equal idea, User.find_by!(hca_uid: "ident!big#{i}").project_idea
    end
  end

  test "an idea too big for the cookie is a friendly error, not a 500" do
    step("age", age_group: "teen")
    step("prize", prize_key: "tshirt")
    step("project", project_kind: "game", project_idea: "😀" * 500)
    assert_response :unprocessable_content
    assert_select ".onboarding__errors", /too many emoji/
  end

  test "the splash and its skip live inside one controller, so the skip actually works; the step is not hidden by its own animation" do
    get onboarding_step_path("age")
    assert_select "section[data-controller~='onboarding-transition'] .transition[data-onboarding-transition-target=overlay][data-action='click->onboarding-transition#skip']"
    assert_select "section[data-action*='turbo:before-cache@document->onboarding-transition#skip']"
    # the entrance animation is on the content, a sibling of the overlay: if it wrapped the overlay, the splash would be invisible
    assert_select ".transition .transition-enter", 0
    assert_select ".onboarding-page__content.transition-enter"
  end


  test "hardware is no longer offered, and a new pick of it is refused" do
    anonymous_through("prize")
    walk_quiz_to("project")
    get onboarding_step_path("project")
    assert_select "input[name='user[project_kind]']", User::OFFERED_PROJECT_KINDS.size
    assert_select "input[name='user[project_kind]'][value=hardware]", 0
    step("project", project_kind: "hardware")
    assert_response :unprocessable_content
    assert_select ".onboarding__errors", /Pick another kind of project/
  end

  test "a signed-out visitor sent here by a sign-in-to-continue redirect gets a Sign in; the landing page itself has none" do
    get dashboard_path
    assert_redirected_to root_path
    follow_redirect!
    assert_select ".site-header__account form[action='/auth/hack_club'] button", "Sign in"
    get root_path
    assert_select ".site-header__account form[action='/auth/hack_club']", 0
  end

  test "the progress strip says in visible text which step you are on, not just with colour" do
    get onboarding_step_path("age")
    assert_select ".onboarding-top #onboarding-progress-step", /\AStep 1 of \d+\z/
    assert_select "progress.onboarding-top__bar[aria-describedby=onboarding-progress-step]"
    anonymous_through("age")
    get onboarding_step_path("prize")
    assert_select "#onboarding-progress-step", /\AStep 2 of \d+\z/
  end

  test "the prize step uses the same cream panel as its siblings, every card has the same structure, and the page carries no extra hint" do
    anonymous_through("age")
    get onboarding_step_path("prize")
    assert_select ".onboarding__panel"
    assert_select ".onboarding__panel--blue", count: 0
    assert_select ".choice-grid--cards .choice", Prize.paid.size
    assert_select ".choice-grid--cards .choice .choice__art ~ .choice__name", Prize.paid.size
    assert_select ".choice__meta", /\Aabout /, Prize.paid.size
    assert_select "p.onboarding__hint", 0 # the page keeps only its heading, one sub-line and the options
  end

  test "the progress label says something different at each step, always starting with 'onboarding progress'" do
    labels = OnboardingsHelper::STEP_COPY.values.map { |copy| copy[:progress] }
    assert_equal labels.size, labels.uniq.size
    labels.each { |label| assert_match(/\Aonboarding progress \(.+\)\z/, label) }
    get onboarding_step_path("age")
    assert_select "#onboarding-progress-label", "onboarding progress (this will be quick, we promise)"
    anonymous_through("age")
    get onboarding_step_path("prize")
    assert_select "#onboarding-progress-label", "onboarding progress (the fun part: picking a prize)"
  end

  test "an onboarded user editing a step sees it as editing, with the way back being the dashboard, and notifications link here" do
    sign_in_as users(:onboarded)
    get onboarding_step_path("schedule")
    assert_select "#onboarding-progress-label", "editing your plan"
    assert_select ".onboarding-top__back", 0

    get settings_notifications_path
    assert_select "a[href='#{onboarding_step_path("schedule")}']", "your schedule"
  end

  test "the draft's steps line up with the controller's" do
    assert_equal Onboarding::Flow.phase("signup"), OnboardingDraft::SIGNUP_STEP
    assert_equal Onboarding::Flow.phase(Onboarding::Flow.keys.last), User::ONBOARDING_STEPS
    assert_equal Onboarding::Flow.phase("prize"), OnboardingDraft::PRIZE_STEP
  end
end
