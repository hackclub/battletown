require "test_helper"

# Every single-choice onboarding question is one component. A step view that writes its own option markup, or a step that asks "pick one"
# with a Continue button, is drift: it fails here.
class OnboardingSingleChoiceTest < ActionDispatch::IntegrationTest
  VIEWS = Dir[Rails.root.join("app/views/onboardings/*.erb")].reject { |f| File.basename(f) == "_choice_group.html.erb" }

  test "no onboarding view writes its own option markup: radios and choice labels live in the shared partial" do
    VIEWS.each do |file|
      source = File.read(file)
      assert_no_match(/radio_button_tag|type="radio"|class="choice\b|age-choice|choice-grid/, source, "#{File.basename(file)} hand-writes option markup")
    end
  end

  test "no onboarding view or helper writes an inline style attribute (the CSP blocks it)" do
    (VIEWS + [ Rails.root.join("app/helpers/onboardings_helper.rb").to_s ]).each do |file|
      assert_no_match(/\bstyle\s*[=:]\s*["']|\bstyle:\s/, File.read(file), "#{File.basename(file)} has an inline style")
    end
  end

  test "the steps that ask a single-choice question render the shared partial" do
    %w[age prize project _schedule_pace _editor_steps].each do |name|
      file = Dir[Rails.root.join("app/views/onboardings/#{name}.html.erb")].first || Dir[Rails.root.join("app/views/onboardings/#{name}*.erb")].first
      assert_match(/render "onboardings\/choice_group"/, File.read(file), "#{name} must render onboardings/choice_group")
    end
  end

  test "single-choice steps have no Continue and every option is one native radio in one group" do
    patch onboarding_step_path("age"), params: { user: { age_group: "teen" } }
    { "prize" => "user[prize_key]" }.each { |step, field| get onboarding_step_path(step); check(field) }
    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
    walk_quiz_to("project")
    get onboarding_step_path("project")
    check("user[project_kind]")
    patch onboarding_step_path("project"), params: { user: { project_kind: "game" } }
    walk_quiz_to("schedule")
    get onboarding_step_path("schedule")
    assert_select "input[type=range]", 1 # the slider step is the one accepted exception: it has a Continue button and no radios
  end

  private

  def check(field)
    assert_response :success
    assert_select "form button.btn", 0, "a single-choice step has no Continue button"
    assert_select "input[type=radio][name='#{field}']" do |inputs|
      assert_operator inputs.size, :>=, 2
    end
    assert_select "[class*=is-picked], [aria-pressed]", 0
  end
end
