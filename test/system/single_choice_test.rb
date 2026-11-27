require "application_system_test_case"

# Walks every single-choice step of the onboarding in a real browser: no Continue, one click advances, rows are one height, and the label
# is vertically centered in its row.
class SingleChoiceSystemTest < ApplicationSystemTestCase
  ROWS = <<~JS.freeze
    (() => [...document.querySelectorAll(".choice-grid--rows .choice")].map((b) => {
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
          for (let e = i.parentElement; e && !e.classList.contains("choice"); e = e.parentElement) {
            const c = getComputedStyle(e)
            if (c.backgroundColor !== "rgba(0, 0, 0, 0)" || parseFloat(c.borderTopWidth) > 0 || parseFloat(c.borderTopLeftRadius) > 0) return e.className
          }
          return null
        }).filter(Boolean)
      JS
      assert_empty boxes, "a prize picture sits in a container: #{boxes.inspect}"
    end
  end

  test "a prize picture with wide transparent margins is cropped to its content in the browser, one that fills its frame is left whole" do
    visit "/onboarding/age"
    find(".transition--welcome").click
    find("label.choice", match: :first).click
    assert_current_path "/onboarding/prize"
    find(".prize-more__toggle").click
    assert_selector ".choice__crop--measured", minimum: 1 # the keyboards and the mouse have margins
    margins = page.evaluate_script('[...document.querySelectorAll(".choice")].map((l) => [l.querySelector(".choice__name").textContent, !!l.querySelector(".choice__crop--measured")])')
    measured = margins.to_h
    assert measured["Aula F75"], "Aula F75 has wide margins and should be cropped"
    assert_not measured["8BitDo Pro 2"], "8BitDo Pro 2 fills its frame and should stay whole"
  end

  VISIBLE_PRIZE_PICTURES = <<~JS.freeze
    (() => [...document.querySelectorAll(".onboarding-dock__image, .choice__image, .reveal__prize-image, .pledge img")].filter((i) => {
      const b = i.getBoundingClientRect(), o = (() => { let v = 1; for (let e = i; e; e = e.parentElement) v *= parseFloat(getComputedStyle(e).opacity); return v })()
      return b.width > 0 && b.height > 0 && o > 0.5
    }).length)()
  JS

  test "the prize picture appears once per screen after the pick (the docked one, or the hero that replaces it, never both)" do
    visit "/onboarding/age"
    find(".transition--welcome").click
    find("label.choice", match: :first).click
    assert_current_path "/onboarding/prize"
    assert_operator page.evaluate_script(VISIBLE_PRIZE_PICTURES), :>=, 6 # the pick step is the one place with many
    find("label.choice", match: :first).click
    %w[project schedule].each do |step|
      assert_current_path "/onboarding/#{step}"
      sleep 1.6 # the flight and the entrance finish
      assert_operator page.evaluate_script(VISIBLE_PRIZE_PICTURES), :<=, 1, "more than one prize picture is visible on #{step}"
      if step == "project" then find("label.choice", text: "Game").click else find("label.choice", match: :first).click end
    end
    assert_current_path "/onboarding/signup"
    sleep 1.6
    assert_operator page.evaluate_script(VISIBLE_PRIZE_PICTURES), :<=, 1, "more than one prize picture is visible on the pledge"
  end

  HEADING_DRIFT = <<~JS.freeze
    (() => {
      const h = document.querySelector(".onboarding__header h1").getBoundingClientRect(), c = document.querySelector(".choice-grid").getBoundingClientRect()
      return Math.abs((h.left + h.width / 2) - (c.left + c.width / 2))
    })()
  JS

  test "the heading is centered over the column on every step, at a desktop and a phone width" do
    [ [ 1781, 1150 ], [ 390, 844 ] ].each do |w, h|
      page.driver.browser.manage.window.resize_to(w, h)
      visit "/onboarding/age"
      find(".transition--welcome").click if page.has_css?(".transition--welcome", wait: 1)
      assert_no_selector ".transition"
      assert_operator page.evaluate_script(HEADING_DRIFT), :<=, 2, "age heading off-center at #{w}"
      find("label.choice", match: :first).click
      assert_current_path "/onboarding/prize"
      assert_operator page.evaluate_script(HEADING_DRIFT), :<=, 2, "prize heading off-center at #{w}"
      find("label.choice", match: :first).click
      assert_current_path "/onboarding/project"
      assert_no_selector ".transition", wait: 6
      assert_operator page.evaluate_script(HEADING_DRIFT), :<=, 2, "project heading off-center at #{w}"
      find("label.choice", text: "Game").click
      assert_current_path "/onboarding/schedule"
      assert_no_selector ".transition", wait: 6
      assert_operator page.evaluate_script(HEADING_DRIFT), :<=, 2, "pace heading off-center at #{w}"
      Capybara.reset_sessions!
    end
  end

  test "I'm not 13-18 shows the ineligible page with a way back" do
    visit "/onboarding/age"
    find(".transition--welcome").click
    find("label.choice", text: "I'm not 13–18").click
    assert_text "Battletown is just for teens"
    click_link "Oops, I picked wrong"
    assert_current_path "/onboarding/age"
  end
end
