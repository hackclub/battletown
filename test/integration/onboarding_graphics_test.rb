require "test_helper"

# The animated graphics of the quiz's info screens: flat inline SVG with the words they carry, and never an inline style (the CSP forbids it).
class OnboardingGraphicsTest < ActionDispatch::IntegrationTest
  def begin_quiz(prize: "tshirt")
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
    patch onboarding_step_path("prize"), params: { user: { prize_key: prize } }
  end

  def open_step(key, prize: "tshirt", kind: "game")
    begin_quiz(prize: prize)
    reach_quiz_step(key, project_kind: kind)
    get onboarding_step_path(key)
    assert_response :success
  end

  def assert_no_inline_style = assert_select "[style]", 0

  test "the pace date screen draws a line of hours from today to the finish date" do
    open_step("pace_date")
    assert_select ".hline svg line, .hline svg path"
    assert_select ".hline__label", /Today/
    assert_select ".hline__label--end", /5 hours/
    assert_select ".hline[role=img][aria-label^='From today, 0 hours, to ']"
    assert_no_inline_style
  end
end
