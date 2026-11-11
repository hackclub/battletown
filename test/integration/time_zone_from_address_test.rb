require "test_helper"

# The address Hack Club Auth returns is used in memory to default users.time_zone and is never kept.
class TimeZoneFromAddressTest < ActionDispatch::IntegrationTest
  STREET = "742 Evergreen Terrace Apt 9Z".freeze
  POSTAL = "98765-4321".freeze
  CITY = "Springfield-Unique".freeze

  setup { OmniAuth.config.test_mode = true }

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  def address(region: "TX", country: "US")
    { "street_address" => STREET, "locality" => CITY, "region" => region, "postal_code" => POSTAL, "country" => country }
  end

  def sign_in_with(uid:, raw_info: {})
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
      provider: "hack_club", uid: uid, extra: { raw_info: { "name" => "Teen", "email" => "teen@example.com" }.merge(raw_info) }
    )
    post "/auth/hack_club"
    follow_redirect!
  end

  def capture_logs
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  test "first sign-in defaults the time zone from the primary address" do
    sign_in_with(uid: "ident!tz-first", raw_info: { "address" => address })
    assert_equal "Central Time (US & Canada)", User.find_by!(hca_uid: "ident!tz-first").time_zone
  end

  test "first sign-in picks the primary entry of an addresses list" do
    sign_in_with(uid: "ident!tz-list", raw_info: { "addresses" => [
      address(country: "FR", region: ""), address(region: "WA").merge("primary" => true)
    ] })
    assert_equal "Pacific Time (US & Canada)", User.find_by!(hca_uid: "ident!tz-list").time_zone
  end

  test "an existing user keeps their chosen time zone on later sign-ins" do
    user = users(:new_user)
    user.update!(time_zone: "Tokyo")
    sign_in_with(uid: user.hca_uid, raw_info: { "address" => address(region: "NY") })
    assert_equal "Tokyo", user.reload.time_zone
  end

  test "a user whose zone is still blank gets it from the address" do
    user = users(:new_user)
    assert_nil user.time_zone
    sign_in_with(uid: user.hca_uid, raw_info: { "address" => address(region: "NY") })
    assert_equal "Eastern Time (US & Canada)", user.reload.time_zone
  end

  test "sign-in without an address still works and leaves the zone blank" do
    sign_in_with(uid: "ident!tz-none")
    user = User.find_by!(hca_uid: "ident!tz-none")
    assert_nil user.time_zone
    assert_redirected_to onboarding_path
  end

  test "an unusable address never blocks sign-in" do
    [ "junk", 12, { "country" => "ZZ" }, [ nil ] ].each_with_index do |value, index|
      sign_in_with(uid: "ident!tz-bad-#{index}", raw_info: { "address" => value })
      assert_redirected_to onboarding_path
      assert_nil User.find_by!(hca_uid: "ident!tz-bad-#{index}").time_zone
    end
  end

  test "the address is not stored anywhere on the user or in the session" do
    sign_in_with(uid: "ident!tz-store", raw_info: { "address" => address })
    user = User.find_by!(hca_uid: "ident!tz-store")
    stored = user.attributes.values.map(&:to_s).join(" ") + session.to_h.to_s
    [ STREET, POSTAL, CITY ].each { |text| assert_not_includes stored, text }
    assert_not_includes user.attributes.keys.join(" "), "address"
    assert_not_includes response.headers.values.join(" "), POSTAL
  end

  test "the address does not appear in the logs" do
    logs = capture_logs { sign_in_with(uid: "ident!tz-log", raw_info: { "address" => address }) }
    assert_includes logs, "SessionsController#create"
    [ STREET, POSTAL, CITY ].each { |text| assert_not_includes logs, text }
  end

  test "address-like params are filtered from request logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("address" => address, "street_address" => STREET, "postal_code" => POSTAL, "locality" => CITY, "region" => "TX")
    assert_not_includes filtered.to_s, STREET
    assert_not_includes filtered.to_s, POSTAL
    assert_not_includes filtered.to_s, CITY
  end

  # -- schedule step ---------------------------------------------------------------------------------

  def at_schedule_step(user)
    user.update!(onboarding_step: 2)
    sign_in_with(uid: user.hca_uid)
    get onboarding_step_path("schedule")
    assert_response :success
  end

  test "schedule step shows one line of context with the zone's display name and a details control" do
    user = users(:new_user)
    user.update!(time_zone: "Eastern Time (US & Canada)")
    at_schedule_step(user)

    assert_select "details.timezone:not([open])" do
      assert_select "summary", /We'll use\s+Eastern Time \(US & Canada\)\s+for your reminders\.\s+Not right\?\s+Change time zone/
      assert_select "select#user_time_zone[name='user[time_zone]']" do
        assert_select "option[selected][value='Eastern Time (US & Canada)']"
      end
    end
    assert_select "form select#user_time_zone", count: 1
    assert_select "label[for=user_time_zone]", text: "Your time zone"
  end

  test "the collapsed select still submits with the form and saves the chosen zone" do
    user = users(:new_user)
    user.update!(time_zone: "Eastern Time (US & Canada)")
    at_schedule_step(user)

    # A closed <details> keeps its controls in the form: the select is inside the form element and not disabled.
    assert_select "form[action='#{onboarding_step_path("schedule")}'] details select[name='user[time_zone]']:not([disabled])"

    patch onboarding_step_path("schedule"), params: { user: { coding_day_names: %w[monday], coding_time: "18:00", time_zone: "Tokyo" } }
    assert_redirected_to onboarding_step_path("account")
    assert_equal "Tokyo", user.reload.time_zone
  end

  test "schedule step opens the details when no zone could be derived" do
    at_schedule_step(users(:new_user))
    assert_select "details.timezone[open]" do
      assert_select "summary", /Which time zone are you in\?/
      assert_select "select#user_time_zone option[selected]", count: 0
    end
  end

  test "schedule step preselects the zone derived at first sign-in" do
    sign_in_with(uid: "ident!tz-step", raw_info: { "address" => address(region: "CA") })
    User.find_by!(hca_uid: "ident!tz-step").update!(onboarding_step: 2)
    get onboarding_step_path("schedule")
    assert_response :success
    assert_select "summary strong", "Pacific Time (US & Canada)"
    assert_select "option[selected][value='Pacific Time (US & Canada)']"
  end

  test "a rejected zone reopens the details" do
    user = users(:new_user)
    user.update!(time_zone: "Eastern Time (US & Canada)")
    at_schedule_step(user)
    patch onboarding_step_path("schedule"), params: { user: { coding_day_names: %w[monday], coding_time: "18:00", time_zone: "Mars/Olympus" } }
    assert_response :unprocessable_content
    assert_select "details.timezone[open]"
  end

  # -- "Every day" -------------------------------------------------------------------------------------

  test "schedule step renders the Every day control, hidden until JavaScript enables it" do
    at_schedule_step(users(:new_user))
    assert_select ".days[data-controller='onboarding-days']" do
      assert_select "input.day__input[type=checkbox]", count: 7
      assert_select "button.day-all[type=button][hidden][aria-pressed=false]", text: "Every day"
    end
  end

  test "Every day starts pressed when all seven days are saved" do
    user = users(:new_user)
    user.update!(coding_days: 127)
    at_schedule_step(user)
    assert_select "button.day-all[aria-pressed=true]"
    assert_select "input.day__input[checked]", count: 7
  end

  test "submitting all seven days saves coding_days as 127" do
    user = users(:new_user)
    at_schedule_step(user)
    patch onboarding_step_path("schedule"), params: { user: { coding_day_names: User::DAYS, coding_time: "18:00", time_zone: "UTC" } }
    assert_redirected_to onboarding_step_path("account")
    assert_equal 127, user.reload.coding_days
  end
end
