require "test_helper"

# First-party analytics, the visitor journey: landing, referral, onboarding before and after sign-up, sign-up, Hackatime and the first project.
# Each event fires once, with exactly the allowlisted properties, and nothing a person typed or chose freely reaches a row.
class AnalyticsJourneyTest < ActionDispatch::IntegrationTest
  IDEA = "A secret farming game about PROBE-IDEA".freeze
  PROBE_ZONE = "Auckland".freeze
  PROBE_NAME = "Probe Teenager".freeze
  PROBE_EMAIL = "probe.teen@example.com".freeze

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    OmniAuth.config.mock_auth[:hackatime] = nil
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_up_as(uid, name: PROBE_NAME, email: PROBE_EMAIL)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: uid, extra: { raw_info: { "name" => name, "email" => email } })
    post "/auth/hack_club", headers: browser_headers
    follow_redirect!(headers: browser_headers)
  end

  def mock_hackatime(uid: "4242", scope: "profile read")
    OmniAuth.config.mock_auth[:hackatime] = OmniAuth::AuthHash.new(provider: "hackatime", uid: uid, credentials: { "token" => "tok-#{uid}", "scope" => scope })
  end

  def connect_hackatime(uid: "4242", scope: "profile read")
    mock_hackatime(uid: uid, scope: scope)
    post "/auth/hackatime", headers: browser_headers
    get "/auth/hackatime/callback", headers: browser_headers
  end

  def step(name, params = {})
    patch onboarding_step_path(name), params: { user: params }, headers: browser_headers
  end

  def view_and_answer(name, params)
    get onboarding_step_path(name), headers: browser_headers
    step(name, params)
  end

  def events(name) = AnalyticsEvent.where(name: name.to_s).order(:id)

  def assert_fired_once(name, props = {})
    found = events(name).to_a
    assert_equal 1, found.size, "expected exactly one #{name}, got #{found.size}"
    assert_equal props.stringify_keys, found.first.props, "#{name} must carry exactly these properties"
    found.first
  end

  def sign_in_returning(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club", headers: browser_headers
    follow_redirect!(headers: browser_headers)
  end

  # --- visitor: landing and referral ---

  test "the landing page records one landing_viewed with no properties, and the referral slug lives on the visit" do
    get "/haven", headers: browser_headers
    assert_fired_once(:referral_link_hit, slug: "haven")

    follow_redirect!(headers: browser_headers)
    assert_fired_once(:landing_viewed)

    visit = AnalyticsVisit.sole
    assert_equal "haven", visit.referral_slug
    assert_equal [ visit.id ], AnalyticsEvent.distinct.pluck(:visit_id)
    assert_nil AnalyticsEvent.where.not(user_id: nil).first
  end

  test "an unknown referral slug records nothing" do
    get "/no-such-slug", headers: browser_headers
    assert_response :not_found
    assert_not_tracked(:referral_link_hit)
    assert_not_tracked(:landing_viewed)
  end

  test "a bot or a Do Not Track visitor records no landing_viewed" do
    get "/", headers: { "User-Agent" => "Slackbot-LinkExpanding 1.0" }
    get "/", headers: browser_headers("DNT" => "1")
    assert_equal 0, AnalyticsEvent.count
  end

  # --- visitor: onboarding before sign-up, then sign-up ---

  test "a visitor's whole journey: every step viewed and completed, the sign-up press, then signed_up on the same visit" do
    get "/haven", headers: browser_headers
    follow_redirect!(headers: browser_headers)
    view_and_answer("age", age_group: "teen")
    assert_fired_once(:onboarding_step_viewed, step: "age")
    view_and_answer("prize", prize_key: "tshirt")
    view_and_answer("project", project_kind: "game", project_idea: IDEA)
    view_and_answer("schedule", coding_day_names: %w[monday friday], coding_time: "18:30", time_zone: PROBE_ZONE, pace_minutes: 45)
    get onboarding_step_path("signup"), headers: browser_headers

    assert_equal %w[age prize project schedule signup], events(:onboarding_step_viewed).map { |event| event.props["step"] }.uniq.sort_by { |name| OnboardingsController::STEPS.index(name) }
    completed = events(:onboarding_step_completed).map(&:props)
    assert_equal [
      { "step" => "age" }, { "step" => "prize", "prize_key" => "tshirt" }, { "step" => "project", "project_kind" => "game", "has_idea" => true },
      { "step" => "schedule", "days_count" => 2, "pace_minutes" => 45 }
    ], completed
    assert_equal [ nil ], events(:onboarding_step_completed).map(&:user_id).uniq, "nobody is signed in yet: the events belong to the visit"

    sign_up_as("ident!probe-journey")
    user = User.find_by!(hca_uid: "ident!probe-journey")

    assert_fired_once(:signup_started)
    assert_fired_once(:signed_up, had_draft: true)
    assert_fired_once(:pace_set, pace_minutes: 45, source: "onboarding")
    assert_not_tracked(:signed_in)
    visit = AnalyticsVisit.sole
    assert_equal user.id, visit.user_id
    assert_equal "haven", visit.referral_slug
    assert_equal [ user.id ], AnalyticsEvent.where(visit_id: visit.id).distinct.pluck(:user_id), "the whole pre-sign-up trail is now the person's"
    assert_fired_once(:project_created, source: "onboarding", project_kind: "game", nth: "1")
  end

  test "signing up with nothing answered first has had_draft false" do
    get "/", headers: browser_headers
    sign_up_as("ident!probe-nodraft")
    assert_fired_once(:signed_up, had_draft: false)
  end

  test "a signed-in person pressing the sign-up button again is not a signup_started" do
    sign_in_returning(users(:new_user))
    AnalyticsEvent.delete_all
    post "/auth/hack_club", headers: browser_headers
    assert_not_tracked(:signup_started)
  end

  test "a person who is not a teen records onboarding_ineligible and no answer" do
    get onboarding_step_path("age"), headers: browser_headers
    step("age", age_group: "adult")
    assert_response :unprocessable_content

    assert_fired_once(:onboarding_ineligible)
    assert_not_tracked(:onboarding_step_completed)
    assert_no_match(/adult/, AnalyticsEvent.pluck(:props).to_json)
  end

  test "a step is viewed again on reload and the event is repeatable, but a finished player editing their plan records no onboarding events" do
    get onboarding_step_path("age"), headers: browser_headers
    get onboarding_step_path("age"), headers: browser_headers
    assert_equal 2, events(:onboarding_step_viewed).count

    AnalyticsEvent.delete_all
    sign_in_returning(users(:onboarded))
    get onboarding_step_path("schedule"), headers: browser_headers
    step("schedule", coding_day_names: %w[monday], coding_time: "18:30", time_zone: "UTC", pace_minutes: 90)
    assert_not_tracked(:onboarding_step_viewed)
    assert_not_tracked(:onboarding_step_completed)
    assert_fired_once(:settings_saved, section: "schedule")
  end

  test "a visitor's answers never become event properties beyond the allowlisted ones" do
    get onboarding_step_path("age"), headers: browser_headers
    step("age", age_group: "teen")
    step("prize", prize_key: "tshirt")
    step("project", project_kind: "app", project_idea: IDEA)
    step("schedule", coding_day_names: %w[tuesday], coding_time: "07:15", time_zone: PROBE_ZONE)
    sign_up_as("ident!probe-privacy")

    dump = [ AnalyticsEvent.pluck(:name, :props, :dedupe_key), AnalyticsVisit.pluck(*AnalyticsVisit.column_names) ].flatten.join(" ")
    [ IDEA, "PROBE-IDEA", PROBE_ZONE, "07:15", PROBE_NAME, PROBE_EMAIL, "ident!probe" ].each do |leak|
      assert_not_includes dump, leak
    end
  end

  # --- returning player ---

  test "a returning player is signed_in once per visit and never signed_up again" do
    sign_in_returning(users(:onboarded))
    assert_fired_once(:signed_in)
    assert_not_tracked(:signed_up)
    visit = AnalyticsVisit.sole
    assert_equal users(:onboarded).id, visit.user_id

    sign_in_returning(users(:onboarded))
    assert_equal 1, events(:signed_in).count, "the same visit signing in twice is one signed_in"
  end

  test "a denied Hack Club consent records auth_failed access_denied, any other failure records other" do
    get "/auth/failure", params: { message: "access_denied", strategy: "hack_club" }, headers: browser_headers
    get "/auth/failure", params: { message: "invalid_credentials PROBE-DETAIL", strategy: "hack_club" }, headers: browser_headers

    assert_equal [ { "strategy" => "hack_club", "reason" => "access_denied" }, { "strategy" => "hack_club", "reason" => "other" } ], events(:auth_failed).map(&:props)
    assert_no_match(/PROBE/, AnalyticsEvent.pluck(:props).to_json)
  end

  # --- onboarding after sign-up: Hackatime, account, finish ---

  test "connecting Hackatime during onboarding: started, linked (first), and finishing records onboarding_completed once" do
    sign_up_as("ident!probe-hackatime")
    user = User.find_by!(hca_uid: "ident!probe-hackatime")
    user.update!(prize_key: "tshirt", project_kind: "game", coding_days: 3, coding_time: "18:30", time_zone: "UTC", onboarding_step: 5)
    AnalyticsEvent.delete_all

    connect_hackatime
    assert_fired_once(:hackatime_connect_started, from: "onboarding")
    assert_fired_once(:hackatime_linked, first: true, from: "onboarding")

    step("account", {})
    step("celebrate", {})
    patch onboarding_step_path("celebrate"), headers: browser_headers
    assert_fired_once(:onboarding_completed)
    assert_equal [ user.id ], AnalyticsEvent.distinct.pluck(:user_id)
  end

  test "reconnecting is not first, and an onboarded player connecting from settings says so" do
    user = users(:onboarded)
    sign_in_returning(user)
    AnalyticsEvent.delete_all

    connect_hackatime(uid: "5555")
    assert_fired_once(:hackatime_connect_started, from: "settings")
    assert_fired_once(:hackatime_linked, first: true, from: "settings")

    connect_hackatime(uid: "5555")
    assert_equal [ true, false ], events(:hackatime_linked).map { |event| event.props["first"] }
  end

  test "the sign-in chain that sends an onboarded player on to Hackatime is from other, on both the press and the link" do
    chain_before = Rails.configuration.x.hackatime.sign_in_chain
    Rails.configuration.x.hackatime.sign_in_chain = true
    sign_in_returning(users(:onboarded)) # no connection: chained, lands on the page that posts itself on
    assert_redirected_to sign_in_hackatime_path
    follow_redirect!
    AnalyticsEvent.delete_all

    mock_hackatime(uid: "6666")
    post "/auth/hackatime", headers: browser_headers
    get "/auth/hackatime/callback", headers: browser_headers

    assert_fired_once(:hackatime_connect_started, from: "other")
    assert_fired_once(:hackatime_linked, first: true, from: "other")
  ensure
    Rails.configuration.x.hackatime.sign_in_chain = chain_before
  end

  test "a denied or incomplete Hackatime link records hackatime_link_failed with a reason, never the provider's words" do
    sign_in_returning(users(:onboarded))
    AnalyticsEvent.delete_all

    get "/auth/failure", params: { message: "access_denied", strategy: "hackatime" }, headers: browser_headers
    get "/auth/failure", params: { message: "weird PROBE-DETAIL", strategy: "hackatime" }, headers: browser_headers
    mock_hackatime(scope: "profile")
    get "/auth/hackatime/callback", headers: browser_headers
    OmniAuth.config.mock_auth[:hackatime] = OmniAuth::AuthHash.new(provider: "hackatime", uid: "not a uid!", credentials: { "token" => "x", "scope" => "profile read" })
    get "/auth/hackatime/callback", headers: browser_headers

    assert_equal %w[access_denied other scope other], events(:hackatime_link_failed).map { |event| event.props["reason"] }
    assert_no_match(/PROBE/, AnalyticsEvent.pluck(:props).to_json)
    assert_not_tracked(:hackatime_linked)
  end

  test "a working Hackatime link that breaks records hackatime_needs_reconnect once, with the error code only" do
    user = users(:onboarded)
    connection = HackatimeConnection.create!(user: user, hackatime_uid: "7777", access_token: "tok", scopes: "profile read", connected_at: Time.current)

    connection.mark_needs_reconnect!("token_revoked")
    connection.mark_needs_reconnect!("token_revoked")

    event = assert_fired_once(:hackatime_needs_reconnect, code: "token_revoked")
    assert_equal user.id, event.user_id
  end

  # --- projects ---

  test "a project made from the projects page records its kind and which one it is for the person, never the name or idea" do
    sign_in_returning(users(:onboarded))
    AnalyticsEvent.delete_all

    post projects_path, params: { project: { name: "Moonbase PROBE-NAME", kind: "tool", idea: IDEA } }, headers: browser_headers
    assert_fired_once(:project_created, source: "projects_page", project_kind: "tool", nth: "1")

    post projects_path, params: { project: { name: "Second", kind: "website" } }, headers: browser_headers
    assert_equal %w[1 2], events(:project_created).map { |event| event.props["nth"] }
    assert_no_match(/PROBE/, AnalyticsEvent.pluck(:props).to_json)
  end

  test "a project_linked event carries the method and no Hackatime project name, for every way a link is made" do
    user = users(:onboarded)
    project = user.projects.create!(name: "Space", kind: "game")

    HackatimeLink.create!(user: user, project: project, hackatime_project: "probe-space-1", link_method: "manual")
    HackatimeLink.create!(user: user, project: project, hackatime_project: "probe-space-2", link_method: "auto_repo")
    HackatimeLink.create!(user: user, project: project, hackatime_project: "probe-space-3", link_method: "confirmed")

    assert_equal %w[manual auto_repo confirmed], events(:project_linked).map { |event| event.props["method"] }
    assert_no_match(/probe-space/, AnalyticsEvent.pluck(:props).to_json)
  end

  # --- settings and profile ---

  test "saving the notification and profile settings records the section only" do
    sign_in_returning(users(:onboarded))
    AnalyticsEvent.delete_all

    patch settings_notifications_path, params: { preferences: {} }, headers: browser_headers
    patch settings_profile_path, params: { profile_name: "Probe Name" }, headers: browser_headers

    assert_equal [ { "section" => "notifications" }, { "section" => "profile" } ], events(:settings_saved).map(&:props)
    assert_no_match(/Probe Name/, AnalyticsEvent.pluck(:props).to_json)
  end

  test "opening your own profile and another player's profile record own true and own false" do
    me = users(:onboarded)
    other = users(:new_user)
    other.update!(onboarded_at: Time.current, profile_name: "Other")
    sign_in_returning(me)
    AnalyticsEvent.delete_all

    get profile_path, headers: browser_headers
    assert_redirected_to player_path(me.public_slug)
    get player_path(me.public_slug), headers: browser_headers
    get player_path(other.reload.public_slug), headers: browser_headers

    assert_equal [ true, false ], events(:profile_viewed).map { |event| event.props["own"] }
    assert_no_match(/#{other.public_slug}|#{me.public_slug}|Other/, AnalyticsEvent.pluck(:props).to_json, "never the address or a name")
  end

  # --- who is never measured ---

  test "a simulated player and staff leave no journey events and no visit behind" do
    ENV["ADMIN_HCA_UIDS"] = "ident!probe-staff"
    %w[sim!probe-one ident!probe-staff].each do |uid|
      reset!
      get "/", headers: browser_headers
      sign_up_as(uid)
      user = User.find_by!(hca_uid: uid)
      patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }, headers: browser_headers
      post "/auth/hackatime", headers: browser_headers
      post projects_path, params: { project: { name: "Mine", kind: "game" } }, headers: browser_headers if user.onboarded?
    end

    assert_equal 0, AnalyticsEvent.count
    assert_equal 0, AnalyticsVisit.where.not(user_id: nil).count
  end
end
