require "test_helper"

# The quiz screens between the prize and the pledge (Onboarding::Flow): generic choice, multi and info pages, their answers kept in the session.
class OnboardingQuizTest < ActionDispatch::IntegrationTest
  def begin_quiz
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
  end

  def answer(step, value) = patch(onboarding_step_path(step), params: { answer: { value: value } })

  test "after the prize the quiz asks what they would do with it, then shows the cost with the prize large and no docked copy" do
    begin_quiz
    assert_redirected_to onboarding_step_path("use")
    follow_redirect!
    assert_select "h1", /What would you do with your 8BitDo Pro 2\?/
    assert_select "#onboarding-prize-dock", Prize.find("tshirt").image.present? ? 1 : 0
    answer("use", "friends")
    assert_redirected_to onboarding_step_path("cost")
    follow_redirect!
    assert_select "#onboarding-prize-dock", 0
    assert_select "img.info__prize", Prize.find("tshirt").image.present? ? 1 : 0
    assert_select "h1", /about 5 hours/
    assert_select "form button.btn", /Continue/
  end

  test "a single choice sends on its own and an answer outside the options is refused" do
    begin_quiz
    answer("use", "nonsense")
    assert_response :unprocessable_content
    assert_select "p.field__error", /Pick an option/
    get onboarding_step_path("use")
    assert_select "form button.btn", 0
    assert_select "input[type=radio][name='answer[value]']", 4
  end

  test "an answer is restored when they come back to the screen" do
    begin_quiz
    answer("use", "alone")
    get onboarding_step_path("use")
    assert_select "input[type=radio][value=alone][checked]", 1
    assert_select "input[type=radio][checked]", 1
  end

  test "Not sure yet skips the follow-up questions and goes to the idea" do
    begin_quiz
    walk_quiz_to("project")
    patch onboarding_step_path("project"), params: { user: { project_kind: "undecided" } }
    assert_redirected_to onboarding_step_path("idea")
    get onboarding_step_path("detail")
    assert_redirected_to onboarding_step_path("idea")
  end

  test "a game goes through its follow-ups and ends with one sentence built from the answers" do
    begin_quiz
    walk_quiz_to("project")
    patch onboarding_step_path("project"), params: { user: { project_kind: "game" } }
    assert_redirected_to onboarding_step_path("detail")
    answer("detail", "puzzle")
    answer("audience", "friends")
    answer("started", "plan")
    answer("size", "weeks")
    assert_redirected_to onboarding_step_path("reflect")
    follow_redirect!
    assert_select "h1", /A puzzle game for your friends, a few weeks of work\./
    assert_select "#onboarding-prize-dock", 0
  end

  test "the obstacle question takes several picks, and its answer screen names only real features" do
    begin_quiz
    reach_quiz_step("stops")
    get onboarding_step_path("stops")
    assert_select "input[type=checkbox][name='answer[values][]']", 5
    patch onboarding_step_path("stops"), params: { answer: { values: [] } }
    assert_response :unprocessable_content
    patch onboarding_step_path("stops"), params: { answer: { values: %w[time lost] } }
    assert_redirected_to onboarding_step_path("stops_answer")
    follow_redirect!
    assert_select ".info__pairs li", 2
    assert_select ".info__pairs", /1 hour/
    assert_select ".info__pairs", /Friday to Thursday/
    get onboarding_step_path("stops")
    assert_select "input[type=checkbox][checked]", 2
  end

  test "picking nothing-stops-me skips the answer screen" do
    begin_quiz
    reach_quiz_step("stops")
    patch onboarding_step_path("stops"), params: { answer: { values: %w[idea none] } }
    assert_redirected_to onboarding_step_path("how")
  end

  test "restarting from the landing resumes at the first unanswered screen" do
    begin_quiz
    walk_quiz_to("project")
    get onboarding_path
    assert_redirected_to onboarding_step_path("project")
  end

  test "a screen further on cannot be opened before the ones before it" do
    begin_quiz
    get onboarding_step_path("how")
    assert_redirected_to onboarding_step_path("use")
  end

  test "the time frame question lists real hours a day for this prize and preselects the matching pace" do
    begin_quiz
    answer("use", "friends")
    walk_quiz_to("when")
    get onboarding_step_path("when")
    assert_select "h1", "When do you want it?"
    assert_select ".choice-grid--rows input[type=radio]", 3
    assert_select ".option-row__note", /about \d+ minutes a day/
    answer("when", "two_weeks")
    reach_quiz_step("schedule")
    get onboarding_step_path("schedule")
    assert_select "input[name='user[pace_minutes]'][value='30'][checked]", 1
  end

  test "with an end date, the end of the program is a time frame and the pace row says when a pace is too slow" do
    ENV["ONBOARDING_PROGRAM_ENDS_ON"] = (Time.zone.today + 9).iso8601 # ten days left, the prize is 5 hours: 30 minutes a day
    begin_quiz
    walk_quiz_to("when")
    get onboarding_step_path("when")
    assert_select "input[value=program]", 1
    assert_select "input[value=month]", 0 # a month is past the end
    ENV["ONBOARDING_PROGRAM_ENDS_ON"] = (Time.zone.today + 2).iso8601 # three days: 30 minutes a day is 1.5 hours, not enough
    reach_quiz_step("schedule")
    get onboarding_step_path("schedule")
    assert_select "label:has(input[value='30']) .choice__meta", "Not in time for the end of the program"
  ensure
    ENV.delete("ONBOARDING_PROGRAM_ENDS_ON")
  end

  test "the editor answer outlives sign-in and prefills the Hackatime step" do
    begin_quiz
    reach_quiz_step("editor")
    answer("editor", "neovim")
    reach_quiz_step("signup")
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: "ident!editor-prefill", extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    get onboarding_step_path("account")
    assert_select "input[type=radio][name=editor][value=neovim][checked]", 1
  end

  test "a person already in never sees the quiz screens" do
    user = users(:new_user)
    user.update!(onboarded_at: Time.current, onboarding_step: User::ONBOARDING_STEPS)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    get onboarding_step_path("use")
    assert_redirected_to dashboard_path
  end
end
