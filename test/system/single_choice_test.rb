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

  test "prize pictures are the subject: each is at least 130px wide on a phone and 180px on a desktop, with no container behind it" do
    visit "/onboarding/age"
    find(".transition--welcome").click
    find("label.choice", match: :first).click
    assert_current_path "/onboarding/prize"
    { [ 390, 844 ] => 130, [ 1781, 1150 ] => 180 }.each do |(w, h), least|
      page.driver.browser.manage.window.resize_to(w, h)
      widths = page.evaluate_script('[...document.querySelectorAll(".choice-grid--cards > .choice .choice__image")].map((i) => i.getBoundingClientRect().width)')
      assert_equal 6, widths.size
      assert widths.all? { |v| v >= least }, "prize pictures narrower than #{least}px at #{w}: #{widths.inspect}"
      boxes = page.evaluate_script(<<~JS)
        [...document.querySelectorAll(".choice__image")].filter((i) => i.offsetParent).map((i) => {
          for (let e = i.parentElement; e && !e.classList.contains("choice__body"); e = e.parentElement) {
            const c = getComputedStyle(e)
            if (c.backgroundColor !== "rgba(0, 0, 0, 0)" || parseFloat(c.borderTopWidth) > 0 || parseFloat(c.borderTopLeftRadius) > 0) return e.className
          }
          return null
        }).filter(Boolean)
      JS
      assert_empty boxes, "a prize picture sits in a container: #{boxes.inspect}"
    end
  end
end
