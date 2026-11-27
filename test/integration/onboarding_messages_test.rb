require "test_helper"
require_relative "../support/hackatime_helper"

# Every error on the onboarding steps is a short instruction (what to do), the day is named when one time is wrong,
# and the idea counter says "N of 500 characters" and the limit in words.
class OnboardingMessagesTest < ActionDispatch::IntegrationTest
  include HackatimeHelper
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
    connect_hackatime_for_session_user if name == "account"
    patch(onboarding_step_path(name), params: { user: params })
  end

  # Hackatime is required to finish the account step, so a test that gets that far has the signed-in person connect first.
  def connect_hackatime_for_session_user
    user = User.find_by(id: session[:user_id])
    connect_hackatime(user, uid: (9000 + user.id).to_s) if user && !user.onboarded? && user.hackatime_connection.nil?
  end

  def anonymous_through(last)
    [
      [ "age", { age_group: "teen" } ],
      [ "prize", { prize_key: "tshirt" } ],
      [ "project", { project_kind: "game", project_idea: "A farming game" } ]
    ].each do |name, params|
      break if name == last

      step(name, params)
    end
  end

  def errors_text = css_select(".onboarding__errors li").map { |li| li.text.squish }

  def refute_old_wording
    assert_no_match(/can't be blank|is too long|must include|must look like|is not included|is invalid|17:30/, response.body)
  end

  test "a missing prize says to pick one, and the line links to the first prize" do
    step("age", age_group: "teen")
    step("prize")
    assert_response :unprocessable_content
    assert_equal [ "Pick a prize to continue" ], errors_text
    assert_select ".onboarding__errors a[href='#user_prize_key_#{Prize.paid.first.key}']", "Pick a prize to continue"
    assert_select "#prize-error", "Pick a prize to continue"
    refute_old_wording
  end

  test "an unknown prize says to pick from the list" do
    step("age", age_group: "teen")
    step("prize", prize_key: "nope")
    assert_equal [ "Pick a prize from the list" ], errors_text
  end

  test "a missing project kind says to pick a kind" do
    anonymous_through("project")
    step("project", project_idea: "x")
    assert_equal [ "Pick a kind of project" ], errors_text
    assert_select ".onboarding__errors a[href='#user_project_kind_game']", "Pick a kind of project"
    assert_select "#kind-error", "Pick a kind of project"
    refute_old_wording
  end

  test "a kind that is no longer offered says to pick another" do
    anonymous_through("project")
    step("project", project_kind: "hardware")
    assert_equal [ "Pick another kind of project. That one isn't offered any more." ], errors_text
  end

  test "an idea over the limit says how to fix it, with the limit from the model" do
    anonymous_through("project")
    step("project", project_kind: "game", project_idea: "a" * 501)
    assert_response :unprocessable_content
    assert_equal [ "Shorten your idea to 500 characters or fewer" ], errors_text
    assert_select ".onboarding__errors a[href='#user_project_idea']"
    assert_select "#user_project_idea-error", "Shorten your idea to 500 characters or fewer"
    refute_old_wording
  end

  test "an idea too big for the cookie keeps its own friendly sentence" do
    anonymous_through("project")
    step("project", project_kind: "game", project_idea: "😀" * 500)
    assert_equal [ "That idea has too many emoji or special characters to save before you sign up. Please shorten it a little." ], errors_text
  end

  test "a project that could not be saved asks to try again" do
    user = users(:new_user)
    user.update!(onboarding_step: 2)
    sign_in_as user
    calls = stub_method(Project, :sync_first_from_onboarding, ->(_user) { false }) do
      step("project", project_kind: "game", project_idea: "A farming game")
    end
    assert_equal 1, calls.size
    assert_response :unprocessable_content
    assert_equal [ "We couldn't save your project just now. Please try again." ], errors_text
    assert_equal 2, user.reload.onboarding_step
  end

  test "the schedule step tells you what to pick, one line per problem" do
    anonymous_through("schedule")
    step("schedule", coding_time: "", time_zone: "")
    assert_response :unprocessable_content
    assert_equal [ "Choose a time to code", "Choose your time zone", "Pick at least one day" ].sort, errors_text.sort
    assert_select "#user_time_zone-error", "Choose your time zone" # the first-run form has no day or time fields to point at
    refute_old_wording
  end

  test "a time that is not a time says to use a time like 5:30 pm" do
    anonymous_through("schedule")
    step("schedule", coding_day_names: %w[monday], coding_time: "99:99", time_zone: "UTC")
    assert_equal [ "Use a time like 5:30 pm" ], errors_text
  end

  test "an unknown time zone says to choose from the list" do
    anonymous_through("schedule")
    step("schedule", coding_day_names: %w[monday], coding_time: "18:00", time_zone: "Mars/Olympus")
    assert_equal [ "Choose your time zone from the list" ], errors_text
  end

  test "one wrong day time names the day" do
    anonymous_through("schedule")
    step("schedule", coding_day_names: %w[monday friday], coding_time: "18:00", time_zone: "UTC", coding_times: { "monday" => "25:99", "friday" => "09:00" })
    assert_equal [ "Check Monday's time: use something like 5:30 pm" ], errors_text
    refute_old_wording
  end

  test "several wrong day times name every day" do
    anonymous_through("schedule")
    step("schedule", coding_day_names: %w[monday tuesday friday], coding_time: "18:00", time_zone: "UTC",
                     coding_times: { "monday" => "25:99", "tuesday" => "9", "friday" => "09:00" })
    assert_equal [ "Check the times for Monday and Tuesday: use something like 5:30 pm" ], errors_text
  end

  test "an unknown way of hearing about us says to pick from the list" do
    user = users(:new_user)
    user.update!(onboarding_step: 5)
    sign_in_as user
    step("account", referral_source: "bing_ads")
    assert_response :unprocessable_content
    assert_equal [ "Pick one of the options in the list" ], errors_text
    assert_select "#user_referral_source-error", "Pick one of the options in the list"
    assert_select ".onboarding__errors a[href='#user_referral_source']"
  end

  test "the idea counter reads as characters, has no live region, and starts at zero" do
    anonymous_through("project")
    get onboarding_step_path("project")
    assert_select "#project-idea-count[data-onboarding-idea-target=counter]", text: /\A\s*0 of 500 characters\s*\z/
    assert_select "#project-idea-count span[data-onboarding-idea-target=count]", "0"
    assert_select "#project-idea-count span[data-onboarding-idea-target=excess]", ""
    assert_select "#project-idea-count[aria-live]", 0
    assert_select "#project-idea-count[role]", 0
    assert_select "#project-idea-count.onboarding__counter--over", 0
    assert_select "textarea#user_project_idea[aria-describedby=project-idea-count]"
  end

  test "after a refused idea the counter says by how much it is too long, in words" do
    anonymous_through("project")
    step("project", project_kind: "game", project_idea: "a" * 512)
    assert_select "#project-idea-count.onboarding__counter--over", text: /512 of 500 characters, too long by 12/
    assert_select "textarea#user_project_idea[aria-describedby='project-idea-count user_project_idea-error']"
    assert_select "#project-idea-count[aria-live]", 0
  end
end
