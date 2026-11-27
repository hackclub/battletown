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

  test "the cost screen shows one block per hour in groups of five, and never more than five groups across" do
    open_step("cost", prize: "tshirt")
    assert_select ".blocks .blocks__block", 5
    assert_select ".blocks__group", 1
    assert_no_inline_style
    open_step("cost", prize: "headphones")
    assert_select ".blocks .blocks__block", 50
    assert_select ".blocks__group", 10
    assert_select ".blocks--cols-5"
  end

  test "how it works shows the four steps as numbered tiles with a drawing each, in order, with the same words" do
    open_step("how")
    assert_select "ol.how li.how__step", 4
    assert_select "ol.how li svg.how__art", 4
    assert_select "ol.how li:nth-child(1) .how__text", "Code, with Hackatime counting the time."
    assert_select "ol.how li:nth-child(4) .how__text", "Coins pay for your prize."
    assert_no_inline_style
  end

  test "each thing that stops them gets a row with an icon badge, in the order picked, and no statistic" do
    begin_quiz
    reach_quiz_step("stops")
    patch onboarding_step_path("stops"), params: { answer: { values: %w[lost time] } }
    get onboarding_step_path("stops_answer")
    assert_select "ul.help li.help__row", 2
    assert_select "ul.help li.help__row .help__badge svg", 2
    assert_select "ul.help li.help__row:first-child strong", "Losing motivation?"
    assert_no_inline_style
  end

  test "the first projects screen sits right before the pace question and carries Hack Club's numbers with their footnote" do
    open_step("small")
    assert_select "h1", "First projects are small"
    assert_select ".bars__value", 3
    assert_select ".bars__value", "54.2%"
    assert_select ".bars__value", "19.7%"
    assert_select ".bars__value", "26.1%"
    assert_equal 100.0, Onboarding::Story::FIRST_PROJECTS.sum { |bar| bar[:percent] }.round(1)
    assert_select ".bars__median-text", /4\.8 hours/
    assert_select ".info__note", "*Based on 17,053 first projects approved by Hack Club."
    assert_no_inline_style
    patch onboarding_step_path("small")
    assert_redirected_to onboarding_step_path("schedule")
  end

  test "the halfway screen shows a badge and the prize with its hours, and its place is the middle of the progress bar" do
    begin_quiz(prize: "tshirt")
    reach_quiz_step("halfway")
    get onboarding_step_path("halfway")
    assert_response :success
    assert_select "h1", "Halfway there"
    assert_select "svg.medal"
    assert_select ".medal__line", "8BitDo Pro 2, about 5 hours of coding."
    assert_select "img.info__prize", 0 # the docked prize is the one picture on the screen
    position, total = css_select("#onboarding-progress-step").first.text.scan(/\d+/).map(&:to_i)
    assert_equal (total / 2.0).round, position
    assert_no_inline_style
  end
end
