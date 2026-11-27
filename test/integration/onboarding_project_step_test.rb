require "test_helper"

# The project step's idea box: the counter must count what the server counts, and the chips must stay usable
# without breaking the form. (The chip behaviour itself lives in onboarding_idea_controller.js.)
class OnboardingProjectStepTest < ActionDispatch::IntegrationTest
  def visit_project_step
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
    get onboarding_step_path("project")
    assert_response :success
  end

  def submit_idea(idea) = patch(onboarding_step_path("project"), params: { user: { project_kind: "game", project_idea: idea } })

  test "the server limit is 500 characters, not bytes, counted after stripping surrounding whitespace" do
    visit_project_step
    submit_idea("  #{"a" * 500}\n ")
    assert_redirected_to onboarding_step_path("schedule")

    visit_project_step
    submit_idea("é" * 500) # two bytes each
    assert_redirected_to onboarding_step_path("schedule")

    visit_project_step
    submit_idea("😀" * 300) # one character each, though two UTF-16 units (600) and four bytes
    assert_redirected_to onboarding_step_path("schedule")

    visit_project_step
    submit_idea("a" * 501)
    assert_response :unprocessable_content
  end
end
