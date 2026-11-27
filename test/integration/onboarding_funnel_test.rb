require "test_helper"
require_relative "../support/hackatime_helper"

# The quiz-funnel screens: the reveal before sign-in, the arrival after it. Set ONBOARDING_FUNNEL_SHOTS to a folder to also
# save each rendered page there (for looking at it in a browser: these steps need an account).
class OnboardingFunnelTest < ActionDispatch::IntegrationTest
  include HackatimeHelper
  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def step(name, params = {}) = patch(onboarding_step_path(name), params: { user: params })

  def visitor_to_reveal(pace: "60")
    step("age", age_group: "teen")
    step("prize", prize_key: "tshirt")
    step("project", project_kind: "game", project_idea: "A farming game")
    step("schedule", coding_day_names: User::DAYS, coding_time: "18:00", time_zone: "UTC", pace_minutes: pace)
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def make_boss(name: "Funnel Boss", hp_hours: 100)
    today = Date.current
    friday = today - ((today.wday - 5) % 7)
    Boss.create!(name: name, art_key: "placeholder", hp_seconds: hp_hours * 3600, starts_on: friday, ends_on: friday + 6)
  end

  def save_shot(name)
    dir = ENV["ONBOARDING_FUNNEL_SHOTS"]
    File.write(File.join(dir, "#{name}.html"), response.body) if dir.present?
  end

  test "the reveal shows the prize with its hours, the pace as days of coding, the project kind and this week's boss, and sign-in keeps it" do
    make_boss
    visitor_to_reveal
    get onboarding_step_path("signup")
    assert_response :success
    assert_select ".onboarding-prize", 0 # the reveal shows the prize itself, not the slim line
    assert_select ".reveal__plan" do
      assert_select "dd", /Battletown T-shirt|8BitDo Pro 2/
      assert_select "dd", /Game/
      assert_select "dd", /60 minutes a day/
      assert_select ".reveal__estimate", /About \d+ days? of coding to your prize\. This is an estimate\./
    end
    assert_select ".reveal__boss .reveal__boss-name", "Funnel Boss"
    assert_select ".reveal__boss", /100% left|Full health|health/i
    assert_select "form[action='/auth/hack_club'] button", /Sign up with Hack Club/
    save_shot("reveal")
  end

  test "the reveal is honest when there is no boss: no boss block and no made-up one" do
    visitor_to_reveal
    get onboarding_step_path("signup")
    assert_response :success
    assert_select ".reveal__boss", 0
  end

  test "the days of coding on the reveal are the same arithmetic the dashboard uses for a new person on that plan" do
    visitor_to_reveal(pace: "120")
    get onboarding_step_path("signup")
    shown = css_select(".reveal__estimate").first.text[/\d+/].to_i

    sign_in_as User.new(hca_uid: "ident!reveal1")
    user = User.find_by!(hca_uid: "ident!reveal1")
    presenter = Dashboard::Presenter.new(user: user)
    date = Date.strptime(presenter.prize_pace.plan[/around (\d+ \w+)/, 1], "%d %b")
    assert_equal shown, (Date.new(presenter.today_date.year, date.month, date.day) - presenter.today_date).to_i
  end

  test "the arrival shows the chosen prize, this week's boss and the one first thing, from what the dashboard has" do
    make_boss(name: "Arrival Boss")
    visitor_to_reveal
    sign_in_as User.new(hca_uid: "ident!arrive1")
    user = User.find_by!(hca_uid: "ident!arrive1")
    connect_hackatime(user, uid: "9101")
    step("account")
    follow_redirect!
    get onboarding_step_path("celebrate")
    assert_response :success
    assert_select ".arrival__prize .arrival__name"
    assert_select ".reveal__boss-name", "Arrival Boss"
    assert_select ".arrival__first .arrival__name"
    assert_select "button", "Enter Battletown"
    assert_select ".celebration__summary", 0 # the recap table is gone
    save_shot("arrival")
  end

  test "the Hackatime step asks which editor, shows only Hackatime's own steps for it, and keeps the choice out of the form" do
    visitor_to_reveal
    sign_in_as User.new(hca_uid: "ident!editor1")
    get onboarding_step_path("account")
    assert_response :success
    assert_select ".editor[data-controller~=onboarding-editor]" do
      assert_select "input[type=radio][name=editor]", OnboardingsHelper::HACKATIME_EDITORS.size + 1
      assert_select "input[name^='user[']", 0 # nothing about the editor is sent to the server
      assert_select "[data-editor=other] a[href='#{OnboardingsHelper::HACKATIME_EDITOR_GUIDES_URL}']"
    end
    assert_select "[data-editor=vscode] a[href='https://hackatime.hackclub.com/setup']"
    assert_select "[data-editor=neovim] code", /vim-wakatime/
    hosts = css_select(".editor a").map { |a| URI(a["href"]).host }.uniq
    assert_equal [ "hackatime.hackclub.com" ], hosts, "every link in the editor steps is Hackatime's own"
    save_shot("account")
  end
end
