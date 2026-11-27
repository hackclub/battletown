require "test_helper"
require_relative "../support/hackatime_helper"

# The schedule step: one usual time, plus optional different times for some days (users.coding_times).
class OnboardingScheduleTest < ActionDispatch::IntegrationTest
  include HackatimeHelper
  WEEK = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
  MIXED = { "monday" => "17:00", "tuesday" => "18:30", "thursday" => "18:30", "sunday" => "18:00" }.freeze

  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def sign_in_as(user, extra: {})
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: extra })
    post "/auth/hack_club"
    follow_redirect!
  end

  def step(name, params = {})
    connect_hackatime_for_session_user if name == "account"
    patch(onboarding_step_path(name), params: { user: params })
  end

  # Hackatime is required to finish the account step, so a test that gets that far has the signed-in person connect first.
  def connect_hackatime_for_session_user
    user = User.find_by(id: session[:user_id])
    connect_hackatime(user, uid: (9000 + user.id).to_s) if user && !user.onboarded? && user.hackatime_connection.nil?
  end

  def visitor_through_project
    step("age", age_group: "teen")
    step("prize", prize_key: "tshirt")
    step("project", project_kind: "game", project_idea: "A farming game")
  end

  def schedule(days: WEEK, time: "18:30", times: {}) = step("schedule", coding_day_names: days, coding_time: time, time_zone: "UTC", coding_times: times)

  def schedule_with_pace(pace) = step("schedule", coding_day_names: WEEK, coding_time: "18:30", time_zone: "UTC", pace_minutes: pace)

  def draft_times = OnboardingDraft.new(session).coding_times

  test "someone editing their plan has an optional time row for every day, labelled, in a closed details" do
    sign_in_as users(:onboarded)
    get onboarding_step_path("schedule")
    assert_select "details.day-times:not([open]) summary", /Different time on some days\?/
    assert_select "details.day-times input[type=time]", 7
    WEEK.each do |day|
      assert_select "input#user_coding_times_#{day}[name='user[coding_times][#{day}]'][type=time]:not([value])"
      assert_select "label[for=user_coding_times_#{day}]", /#{day.capitalize}\s+\(optional\)/
    end
    assert_select "input[name='user[coding_time]']" # the usual time stays as it was
    assert_select "form[data-controller~='onboarding-times'][data-action~='change->onboarding-times#sync']"
    assert_select "input.day__input[data-onboarding-times-target=day]", 7
  end

  def draft_pace = OnboardingDraft.new(session).pace_minutes

  test "the first run asks one question, the pace, as big buttons that carry the days and time" do
    visitor_through_project
    get onboarding_step_path("schedule")
    assert_select "h1", /How long is a coding day\?/
    assert_select ".choice-grid--rows input[type=radio][name='user[pace_minutes]']", 4
    assert_select "label:has(input[name='user[pace_minutes]'][value='60']) .choice__name", /1 hour/
    assert_select "label:has(input[name='user[pace_minutes]'][value='60']) .choice__meta", /About \d+ days? to your /
    assert_select "input[type=hidden][name='user[coding_day_names][]']", 7
    assert_select "input[type=hidden][name='user[coding_time]'][value='18:00']"
    assert_select "select#user_time_zone", 0 # the browser's zone is sent in a hidden field; nothing is asked
    assert_select "input[type=hidden][name='user[time_zone]']"
    assert_select "#pace-hint", 0
    assert_select "select, input[type=time], .day-times", 0 # no dropdown, no time pickers, no time zone select
    assert_select ".choice-grid--rows input[checked]", 0
  end

  test "someone editing their plan still gets the daily pace as a select with the saved one chosen" do
    sign_in_as users(:onboarded)
    get onboarding_step_path("schedule")
    assert_select "label[for=user_pace_minutes]", "How long will you code on those days?"
    assert_select "select#user_pace_minutes[name='user[pace_minutes]'][aria-describedby='pace-hint']" do
      assert_select "option", 8
      assert_select "option[selected]", 1
      assert_select "option[selected][value='60']", "1 hour"
      assert_select "option[value='15']", "15 minutes"
      assert_select "option[value='90']", "1 hour 30 minutes"
      assert_select "option[value='240']", "4 hours"
    end
    assert_select "#pace-hint", "This is the pace your prize check on the dashboard uses. You can change it any time."
  end

  test "the pace buttons' days of coding match the plan line the dashboard gives a new person" do
    user = users(:new_user)
    user.update!(prize_key: "tshirt", pace_minutes: 60, coding_days: 127, coding_time: "18:00", time_zone: "UTC", onboarding_step: 3)
    sign_in_as user
    get onboarding_step_path("schedule")
    shown = css_select("label:has(input[name='user[pace_minutes]'][value='60']) .choice__meta").first.text[/\d+/].to_i
    plan = Dashboard::Presenter.new(user: user).prize_pace.plan
    date = Date.strptime(plan[/around (\d+ \w+)/, 1], "%d %b")
    today = Dashboard::Presenter.new(user: user).today_date
    assert_equal shown, (Date.new(today.year, date.month, date.day) - today).to_i
  end

  test "a visitor's pace is kept on the draft, shown again, and copied to the account at sign-up" do
    visitor_through_project
    schedule_with_pace("120")
    assert_redirected_to onboarding_step_path("signup")
    assert_equal 120, draft_pace

    get onboarding_step_path("schedule")
    assert_select "input[name='user[pace_minutes]'][value='120'][checked]"
    assert_select ".choice-grid--rows input[checked]", 1
    assert_select "[class*=is-picked], .choice-grid--rows [aria-pressed]", 0

    sign_in_as User.new(hca_uid: "ident!pace1")
    assert_equal 120, User.find_by!(hca_uid: "ident!pace1").pace_minutes
  end

  test "a blank pace leaves it unset, and the default is assumed" do
    visitor_through_project
    schedule_with_pace("")
    assert_redirected_to onboarding_step_path("signup")
    assert_nil draft_pace
    sign_in_as User.new(hca_uid: "ident!pace2")
    user = User.find_by!(hca_uid: "ident!pace2")
    assert_nil user.pace_minutes
    assert_equal User::PACE_DEFAULT, user.pace
  end

  test "a pace that is not on the list is a friendly error, and nothing is saved" do
    visitor_through_project
    [ "7", "abc", "-30", "15.5", "15abc" ].each do |odd|
      schedule_with_pace(odd)
      assert_response :unprocessable_content, odd
      assert_select ".onboarding__errors", /Pick a pace from the list/, odd
      assert_select ".onboarding__errors a[href='#user_pace_minutes']"
      assert_select "#user_pace_minutes" # the link lands on the first pace button
      assert_select "fieldset[aria-describedby=pace-error] #pace-error", /Pick a pace from the list/
      assert_nil draft_pace, odd
    end
    get onboarding_step_path("signup")
    assert_redirected_to onboarding_step_path("schedule")
  end

  test "a signed-in edit of the schedule saves the pace, and a bad one is refused" do
    user = users(:onboarded)
    sign_in_as(user)
    get onboarding_step_path("schedule")
    assert_select "select#user_pace_minutes option[selected][value='60']"

    step("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC", pace_minutes: "120")
    assert_redirected_to dashboard_path
    assert_equal 120, user.reload.pace_minutes

    step("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC", pace_minutes: "7")
    assert_response :unprocessable_content
    assert_select ".onboarding__errors", /Pick a pace from the list/
    assert_equal 120, user.reload.pace_minutes

    step("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC")
    assert_equal 120, user.reload.pace_minutes, "a form that sends no pace leaves it alone"
  end

  test "a draft with a pace still fits in the session cookie next to the biggest idea" do
    get "/haven"
    step("age", age_group: "teen")
    step("prize", prize_key: "tshirt")
    step("project", project_kind: "game", project_idea: "😀" * 300)
    step("schedule", coding_day_names: WEEK, coding_time: "18:30", time_zone: "UTC", pace_minutes: "240", coding_times: WEEK.to_h { |day| [ day, "23:59" ] })
    assert_redirected_to onboarding_step_path("signup")
    assert_operator response.headers["set-cookie"].to_s[/_[a-z_]+session=[^;]*/].bytesize, :<, 3600
  end

  test "a visitor's times by day are kept in the session, shown again, and read well in the plan" do
    visitor_through_project
    schedule(days: %w[monday tuesday thursday sunday], times: MIXED.merge("friday" => "09:00", "bogus" => "10:00"))
    assert_redirected_to onboarding_step_path("signup")
    assert_equal MIXED, draft_times, "a day that is not selected and an unknown day are dropped"

    get onboarding_step_path("schedule") # the pace question does not touch them
    assert_response :success
    schedule_with_pace("60")
    assert_equal MIXED, draft_times, "a pace answer that sends no times leaves the saved ones alone"
  end

  test "the times come with the visitor onto the account at sign-up" do
    visitor_through_project
    schedule(days: %w[monday tuesday thursday sunday], times: MIXED)
    sign_in_as User.new(hca_uid: "ident!times1")
    user = User.find_by!(hca_uid: "ident!times1")
    assert_equal MIXED, user.coding_times
    assert_equal "18:30", user.coding_time
    assert_equal "17:00", user.coding_time_for("monday")
    assert_equal "18:30", user.coding_time_for(:thursday)

    step("account")
    get onboarding_step_path("celebrate")
    assert_response :success
  end

  test "without different times the plan reads as before" do
    visitor_through_project
    schedule
    get onboarding_step_path("signup")
    assert_select ".pledge__text"
    assert_equal({}, draft_times)

    schedule(days: %w[monday friday], times: { "monday" => "", "friday" => " " })
    assert_equal({}, draft_times, "blank means the usual time")
    get onboarding_step_path("signup")
    assert_select ".pledge__text"
  end

  test "a time that is not HH:MM is an error that points at the field, and nothing is saved" do
    sign_in_as users(:onboarded)
    schedule(days: %w[monday friday], times: { "monday" => "25:99" })
    assert_response :unprocessable_content
    assert_select ".onboarding__errors", /Check Monday's time: use something like 5:30 pm/
    assert_select ".onboarding__errors a[href='#day-times-hint']"
    assert_select "details.day-times[open] .field__error"
    assert_select "input#user_coding_times_monday[aria-invalid=true]"
  end

  test "a bad time sent to a visitor is refused and the draft keeps nothing" do
    visitor_through_project
    schedule(days: %w[monday friday], times: { "monday" => "25:99" })
    assert_response :unprocessable_content
    assert_select ".onboarding__errors", /Check Monday's time/
    assert_equal({}, draft_times)
    get onboarding_step_path("signup")
    assert_redirected_to onboarding_step_path("schedule")
  end

  test "odd shapes are ignored or rejected, never a 500" do
    visitor_through_project
    [ "monday", [ "17:00" ], { "monday" => [ "17:00" ] }, { "monday" => { "a" => "b" } }, { "__proto__" => "17:00" } ].each do |odd|
      assert_nothing_raised { schedule(days: %w[monday friday], times: odd) }
      assert_includes [ 302, 422 ], response.status, odd.inspect
      assert_not_equal MIXED, draft_times
    end
    patch onboarding_step_path("schedule"), params: { user: { coding_day_names: [ "monday" ], coding_time: "18:30", time_zone: "UTC", coding_times: { monday: "07:00" } } }
    assert_equal({ "monday" => "07:00" }, draft_times)
  end

  test "a schedule step that sends no times leaves the saved ones alone" do
    visitor_through_project
    schedule(days: %w[monday friday], times: { "monday" => "17:00" })
    step("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC")
    assert_equal({ "monday" => "17:00" }, draft_times)
  end

  test "the biggest idea and a different time on every day still fit in the session cookie" do
    [ "x" * 500, "😀" * 300 ].each_with_index do |idea, i|
      reset!
      get "/haven" # the session also carries the referral slug
      step("age", age_group: "teen")
      step("prize", prize_key: "tshirt")
      step("project", project_kind: "game", project_idea: idea)
      schedule(times: WEEK.to_h { |day| [ day, "23:59" ] })
      assert_redirected_to onboarding_step_path("signup"), "idea #{i}"
      cookie = response.headers["set-cookie"].to_s[/_[a-z_]+session=[^;]*/]
      assert_operator cookie.bytesize, :<, 3600, "idea #{i} leaves no room in the 4096-byte cookie"
      sign_in_as User.new(hca_uid: "ident!bigtimes#{i}")
      assert_equal idea, User.find_by!(hca_uid: "ident!bigtimes#{i}").project_idea
      assert_equal 7, User.find_by!(hca_uid: "ident!bigtimes#{i}").coding_times.size
    end
  end

  test "a draft's schedule replaces the overrides an unfinished account already had" do
    user = User.create!(hca_uid: "ident!times2", coding_days: 1, coding_time: "10:00", coding_times: { "monday" => "09:00" })
    draft = OnboardingDraft.new({})
    draft.assign_attributes(prize_key: "tshirt", coding_day_names: %w[tuesday], coding_time: "19:00", time_zone: "UTC", onboarding_step: 3)
    assert draft.apply_to(user)
    assert_equal({}, user.coding_times)

    other = User.new(hca_uid: "ident!times3", coding_times: { "monday" => "09:00" })
    assert OnboardingDraft.new({}).tap { |d| d.assign_attributes(prize_key: "tshirt", onboarding_step: 2) }.apply_to(other)
    assert_equal({ "monday" => "09:00" }, other.coding_times, "a draft with no schedule leaves the account's alone")
  end

  # Existing accounts: an onboarded user editing the schedule, with and without different times.
  test "an onboarded user with no different times sees an empty form and saves as before" do
    user = users(:onboarded)
    assert_equal({}, user.coding_times)
    sign_in_as(user)
    get onboarding_step_path("schedule")
    assert_select "details.day-times:not([open])"
    assert_select "details.day-times input[type=time]:not([value])", 7
    step("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC")
    assert_redirected_to dashboard_path
    assert_equal({}, user.reload.coding_times)
  end

  test "an onboarded user can set and clear different times, and the queued reminder follows" do
    user = users(:onboarded)
    sign_in_as(user, extra: { "slack_id" => "UTESTTIMES1" })
    travel_to Time.utc(2026, 11, 22, 12) do # a Sunday
      step("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC", coding_times: { "monday" => "17:00", "wednesday" => "08:00" })
      assert_redirected_to dashboard_path
      assert_equal({ "monday" => "17:00" }, user.reload.coding_times)
      assert_equal Time.utc(2026, 11, 23, 17, 0), Notification.pending.find_by!(user_id: user.id, kind: "daily_reminder").scheduled_for

      step("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: "UTC", coding_times: { "monday" => "", "friday" => "" })
      assert_equal({}, user.reload.coding_times)
      assert_equal Time.utc(2026, 11, 23, 18, 30), Notification.pending.find_by!(user_id: user.id, kind: "daily_reminder").scheduled_for
    end
  end

  test "unselecting a day drops its time" do
    user = users(:onboarded)
    user.update!(coding_days: 5, coding_times: { "monday" => "17:00", "wednesday" => "16:00" })
    assert_equal({ "monday" => "17:00", "wednesday" => "16:00" }, user.reload.coding_times)
    user.update!(coding_day_names: %w[wednesday])
    assert_equal({ "wednesday" => "16:00" }, user.reload.coding_times)
  end

  test "the database refuses a coding_times that is not an object" do
    assert_raises(ActiveRecord::StatementInvalid) { users(:onboarded).update_column(:coding_times, [ "17:00" ]) }
  end

  # -- the browser's time zone is sent with the pace step and never asked ----------------------------------

  def pace_with_zone(zone)
    visitor_through_project
    step("schedule", pace_minutes: "60", coding_day_names: User::DAYS, coding_time: "18:00", time_zone: zone)
    OnboardingDraft.new(session).time_zone
  end

  test "a known IANA zone from the browser is saved as the app's zone name" do
    assert_equal "Eastern Time (US & Canada)", pace_with_zone("America/New_York")
  end

  test "UTC from a CI browser maps cleanly" do
    assert_equal "UTC", pace_with_zone("UTC")
  end

  test "a missing or unknown IANA zone falls back to UTC and never to the raw value" do
    assert_equal "UTC", pace_with_zone("")
    assert_equal "UTC", pace_with_zone("Mars/Olympus")
  end

  test "the pace line names the picked prize and counts the days to it, and no prize gives no days line" do
    visitor_through_project
    get onboarding_step_path("schedule")
    prize = Prize.find(OnboardingDraft.new(session).prize_key)
    assert_select "h1 + .onboarding__encouragement, .onboarding__encouragement", /#{Regexp.escape(prize.name)}/
    days = (Rational(prize.coins * 3600, Game::Config.current.coins_per_hour) / (60 * 60)).ceil
    assert_select "label:has(input[name='user[pace_minutes]'][value='60']) .choice__meta", "About #{days} #{"day".pluralize(days)} to your #{prize.name}"
  end
end

class OnboardingsHelperScheduleTest < ActionView::TestCase
  include OnboardingsHelper

  test "paces read in plain words" do
    assert_equal [ "15 minutes", "30 minutes", "45 minutes", "1 hour", "1 hour 30 minutes", "2 hours", "3 hours", "4 hours" ], pace_options.map(&:first)
    assert_equal User::PACES, pace_options.map(&:last)
  end

  def plan(days, time, times = {}) = coding_schedule_text(User.new(coding_day_names: days, coding_time: time, coding_times: times))

  test "one time for every day keeps the usual wording" do
    assert_equal "Every day at 6:30 pm", plan(User::DAYS, "18:30")
    assert_equal "Monday and Friday at 6:30 pm", plan(%w[monday friday], "18:30")
    assert_equal "Monday, Wednesday, and Friday at 9:05 am", plan(%w[monday wednesday friday], "09:05")
    assert_equal "Monday and Friday at 6:30 pm", plan(%w[monday friday], "18:30", { "monday" => "18:30" }), "an override equal to the usual time changes nothing"
  end

  test "different times group the days by time, in week order" do
    assert_equal "Mon at 5:00 pm, Tue and Thu at 6:30 pm, Sun at 6:00 pm",
                 plan(%w[monday tuesday thursday sunday], "18:30", { "monday" => "17:00", "sunday" => "18:00" })
    assert_equal "Mon, Tue and Wed at 6:30 pm, Fri at 8:00 am", plan(%w[monday tuesday wednesday friday], "18:30", { "friday" => "08:00" })
    assert_equal "Mon at 5:00 pm, Tue at 6:00 pm", plan(%w[monday tuesday], nil, { "monday" => "17:00", "tuesday" => "18:00" })
    assert_equal "Mon at 5:00 pm, Tue", plan(%w[monday tuesday], nil, { "monday" => "17:00" })
  end

end
