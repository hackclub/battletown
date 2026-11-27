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
    assert_select "ol.ob-how li.ob-how__step", 4
    assert_select "ol.ob-how li svg.ob-how__art", 4
    assert_select "ol.ob-how li:nth-child(1) .ob-how__text", "Code, with Hackatime counting the time."
    assert_select "ol.ob-how li:nth-child(4) .ob-how__text", "Coins pay for your prize."
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

  test "the pace step is a four-stop slider with the stop that meets the wish preselected, and its Continue posts the same param" do
    begin_quiz(prize: "mechanical_keyboard")
    reach_quiz_step("when")
    patch onboarding_step_path("when"), params: { answer: { value: "month" } }
    reach_quiz_step("schedule")
    get onboarding_step_path("schedule")
    assert_select "input[type=range][min='0'][max='2'][step='1'][value='0']", 1 # 30 hours: 1, 2 and 3 hours a day finish in time; a month needs 1 hour
    assert_select ".slider__stop", 3
    assert_select ".slider__stop[data-minutes='60'][data-finish^='About 30 days']"
    assert_select "input[type=hidden][name='user[pace_minutes]'][value='60']", 1
    assert_select ".onboarding__actions .btn", /Continue/
    assert_select ".onboarding__encouragement", "You wanted it in a month."
    assert_no_inline_style
    patch onboarding_step_path("schedule"), params: { user: { pace_minutes: 120, coding_day_names: %w[monday], coding_time: "18:00", time_zone: "UTC" } }
    assert_redirected_to onboarding_step_path("pace_date")
    get onboarding_step_path("schedule")
    assert_select "input[type=range][value='1']", 1 # going back restores the stop
  end

  test "the summary shows the next seven days, a bar on each coding day, today marked" do
    open_step("summary")
    assert_select ".week .week__day", 7
    assert_select ".week__day--today", 1
    assert_select ".week__bar", minimum: 1 # one per saved coding day
    assert_select ".week__day--boss", 0 # no boss covers today
    assert_no_inline_style
  end

  test "the summary strip marks only the saved coding days and flags the day this week's boss ends" do
    today = Date.current
    friday = today - ((today.wday - 5) % 7)
    Boss.create!(name: "Strip Boss", art_key: "placeholder", hp_seconds: 100 * 3600, starts_on: friday, ends_on: friday + 6)
    begin_quiz
    reach_quiz_step("schedule", project_kind: "game")
    patch onboarding_step_path("schedule"), params: { user: { pace_minutes: 60, coding_day_names: %w[monday wednesday], coding_time: "18:00", time_zone: "UTC" } }
    reach_quiz_step("summary", project_kind: "game")
    get onboarding_step_path("summary")
    assert_select ".week__bar", 2
    assert_select ".week__day--boss", 1
    assert_select ".week__flag svg", 1
    assert_no_inline_style
  end
end
