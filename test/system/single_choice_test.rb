require "application_system_test_case"

# Walks every single-choice step of the onboarding in a real browser: no Continue, one click advances, rows are one height, and the label
# is vertically centered in its row.
class SingleChoiceSystemTest < ApplicationSystemTestCase
  ROWS = <<~JS.freeze
    (() => [...document.querySelectorAll(".choice-grid--rows .choice__body")].map((b) => {
      const r = b.getBoundingClientRect(), n = b.querySelector(".choice__name").getBoundingClientRect()
      return { h: r.height, off: (n.top + n.height / 2) - (r.top + r.height / 2) }
    }))()
  JS

  def assert_rows_even
    rows = page.evaluate_script(ROWS)
    assert rows.map { |r| r["h"].round }.uniq.one?, "rows differ in height: #{rows.inspect}"
    assert rows.all? { |r| r["off"].abs <= 1 }, "a label is not centered: #{rows.inspect}"
  end

  test "age, prize, project kind and pace are one component: no Continue, one click advances, even rows" do
    visit "/onboarding/age"
    find(".transition--welcome").click
    assert_no_selector ".transition"
    assert_no_button "Continue"
    assert_rows_even
    find("label.choice", match: :first).click
    assert_current_path "/onboarding/prize"
    assert_no_button "Continue"
    find("label.choice", match: :first).click
    assert_current_path "/onboarding/project"
    assert_no_selector ".transition", wait: 6
    assert_no_button "Continue"
    assert_rows_even
    heights = page.evaluate_script(ROWS).map { |r| r["h"].round }
    find("label.choice", text: "Game").click
    assert_current_path "/onboarding/schedule"
    assert_no_selector ".transition", wait: 6
    assert_no_button "Continue"
    assert_rows_even
    assert_equal heights.first, page.evaluate_script(ROWS).first["h"].round, "rows differ in height between steps"
  end
end
