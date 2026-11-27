require "application_system_test_case"
require_relative "../support/orders_helper"

# Every icon sits in the center of its box, measured in a real browser (the CI `system-test` job; runs with
# `bin/rails test:system`). The convention is in app/helpers/icon_helper.rb: an inline <svg> inside a container marked
# data-icon-box (data-icon-axis="y" when the icon sits beside a label).
#
# The measuring is test/support/icon_center_probe.js: the icon's drawn geometry (each shape's bounding box through its
# screen transform, so the viewBox and any rotation count) against the center of the box's content box, in screen px.
# Above TOLERANCE on either axis fails, and the message names the page, the width, the box and the icon. An <svg> in a
# link, button, summary, label or badge with no data-icon-box also fails: an icon that skips the marking would never be
# measured. (A text glyph used as an icon is caught by test/integration/icon_glyphs_test.rb.)
#
# Not covered: pages behind data this test does not build (a ship result, the Hackatime link page, the sign-in-gated
# onboarding steps after sign-up) and the state icons of other states than the ones the pages are in. Run
# .claude/skills/verify/icon_offsets.py on such a page, or add it here.
class IconCenteringSystemTest < ApplicationSystemTestCase
  include OrdersTestHelper

  TOLERANCE = 0.5
  SIZES = { "desktop" => [ 1400, 1000 ], "phone" => [ 390, 844 ] }.freeze
  # (Selenium evaluates "return <script>", so the probe's leading comment lines must go: they would end the statement after `return`.)
  PROBE = File.readlines(Rails.root.join("test/support/icon_center_probe.js")).reject { |line| line.start_with?("//") }.join

  setup do
    OmniAuth.config.test_mode = true
    @offences = [] # (not @failures: Minitest keeps its own list under that name)
    @measured = Hash.new(0)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    teardown_orders_world if instance_variable_defined?(:@staff)
  end

  test "icons on the pages anyone can open, and through the onboarding steps, are centered" do
    visit root_path
    assert_selector ".faq summary"
    measure "landing"

    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: "ident!icon-center", extra: { raw_info: {} })
    first(".hero a.cta").click
    assert_current_path "/onboarding/age"
    find(".transition--welcome").click
    assert_no_selector ".transition"
    measure "onboarding age"
    click_button "I'm a teen aged 13–18!"
    assert_current_path "/onboarding/prize"
    measure "onboarding prize"
    find("label.choice", match: :first).click
    measure "onboarding prize (a choice picked)"
    click_button "Continue"
    assert_current_path "/onboarding/project"
    assert_selector ".transition--proof" # the "others like you" moment plays over this step; measure once it has faded
    assert_no_selector ".transition", wait: 6
    find("label.toggle", text: "Game").click
    measure "onboarding project"
    click_button "Continue"
    assert_current_path "/onboarding/schedule"
    assert_selector ".transition--proof"
    assert_no_selector ".transition", wait: 6
    measure "onboarding schedule"

    visit terms_path
    measure "terms"
    assert_icons_centered
  end

  test "icons on the signed-in pages are centered" do
    setup_orders_world(coins: 1000)
    %w[requested on_hold shipped fulfilled cancelled refunded].each { |status| order_in(status) }
    sign_in_in_browser @buyer

    [ dashboard_path, merch_path, shop_path, orders_path, order_path(@buyer.orders.order(:id).first), order_path(@buyer.orders.order(:id).last),
      projects_path, ships_path, settings_notifications_path ].each { |path| visit path; measure path }
    assert_icons_centered
  end

  test "icons on the staff pages are centered" do
    setup_orders_world(coins: 1000)
    order = order_in("shipped")
    sign_in_in_browser @staff

    [ admin_root_path, admin_orders_path, admin_order_path(order), admin_ships_path, admin_users_path ].each { |path| visit path; measure path }
    assert_icons_centered
  end

  private

  # The sign-in is a POST with the CSRF token, so a form is posted from the page itself; OmniAuth's test mode answers for Hack Club.
  def sign_in_in_browser(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    visit root_path
    page.execute_script(<<~JS)
      const form = document.createElement("form"); form.method = "post"; form.action = "/auth/hack_club"
      const token = document.createElement("input"); token.type = "hidden"; token.name = "authenticity_token"
      token.value = (document.querySelector("meta[name=csrf-token]") || {}).content || "" // the test environment has forgery protection off
      form.appendChild(token); document.body.appendChild(form); form.submit()
    JS
    assert_no_current_path root_path
  end

  def measure(name)
    SIZES.each do |size, (width, height)|
      page.driver.browser.manage.window.resize_to(width, height)
      page.evaluate_script("document.fonts.ready.then(() => true)")
      2.times do |pass|
        # The second pass shows the state icons: every <details> open, every toggle picked (put back afterwards, so the walk goes on).
        page.execute_script(<<~JS) if pass == 1
          window.__iconRevert = [...document.querySelectorAll("details:not([open])")].map((d) => () => (d.open = false))
          document.querySelectorAll("details").forEach((d) => (d.open = true))
          document.querySelectorAll(".toggle__input").forEach((i) => { const was = i.checked; i.checked = true; window.__iconRevert.push(() => (i.checked = was)) })
        JS
        result = page.evaluate_script(PROBE)
        page.execute_script("(window.__iconRevert || []).forEach((undo) => undo()); window.__iconRevert = []") if pass == 1
        @measured[name] += result["icons"].size
        result["icons"].each { |icon| puts "#{name} (#{size}): #{icon['box']} > #{icon['icon']} [#{icon['axis']}] dx #{icon['dx']} dy #{icon['dy']}" } if ENV["ICON_REPORT"]
        result["unmarked"].each { |icon| @offences << "#{name} (#{size}): #{icon} is an icon in a control with no data-icon-box" }
        result["icons"].select { |icon| icon["off"] > TOLERANCE }.each do |icon|
          @offences << "#{name} (#{size}, #{width}px): #{icon['icon']} in #{icon['box']} is #{icon['dx']}px across and #{icon['dy']}px down from the center (the limit is #{TOLERANCE}px)"
        end
      end
    end
    page.driver.browser.manage.window.resize_to(*SIZES["desktop"])
  end

  def assert_icons_centered
    @offences.uniq!
    assert_empty @offences, "Icons off-center (draw them with IconHelper#icon in a data-icon-box):\n#{@offences.join("\n")}"
    assert_operator @measured.values.sum, :>, 0, "the probe measured no icon at all: the check is not looking at anything"
  end
end
