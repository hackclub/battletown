require "test_helper"
require_relative "../support/admin_sign_in"
require_relative "../support/ships_test_support"
require_relative "../support/shop_helper"

class AdminUsersTest < ActionDispatch::IntegrationTest
  include AdminSignIn
  include ShipsTestSupport
  include ShopTestHelper

  setup do
    travel_to Time.utc(2026, 11, 12, 15)
    @staff = users(:onboarded)
    @teen = users(:new_user)
    @teen.update_columns(display_name: "Zed Teenager", email: "zed.teen@example.test", slack_id: "U0ZEDTEEN", time_zone: "UTC",
                         verification_status: "verified", ysws_eligible: true, referral_source: "haven",
                         onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
  end

  def query_log
    io = StringIO.new
    original = [ Rails.logger, ActiveRecord::Base.logger, ActionController::Base.logger ]
    logger = ActiveSupport::Logger.new(io)
    logger.level = Logger::DEBUG
    Rails.logger = ActiveRecord::Base.logger = ActionController::Base.logger = logger
    yield
    io.string
  ensure
    Rails.logger, ActiveRecord::Base.logger, ActionController::Base.logger = original
  end

  # --- the list ---
  # The generic tables in route_security_test.rb read the router, so these routes are already covered there; this pins the list
  # so that dropping or adding one is a visible decision.
  test "the staff user routes are exactly these, and every one is a 404 for a signed-out visitor and a non-admin" do
    found = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      [ route.verb, path ] if path.start_with?("/admin/users", "/admin/audit")
    end
    assert_equal [ %w[GET /admin/audit], %w[GET /admin/users], %w[GET /admin/users/:id], %w[GET /admin/users/:user_id/coins/new],
                   %w[GET /admin/users/:user_id/hours/new], %w[POST /admin/users/:user_id/coins], %w[POST /admin/users/:user_id/coins/confirm],
                   %w[POST /admin/users/:user_id/hours], %w[POST /admin/users/:user_id/hours/confirm], %w[POST /admin/users/:user_id/notes] ].sort, found.sort
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    [ nil, @staff ].each do |visitor|
      sign_in_as(visitor) if visitor
      found.each do |verb, path|
        process(verb.downcase.to_sym, path.sub(":user_id", @teen.id.to_s).sub(":id", @teen.id.to_s))
        assert_response :not_found, "#{verb} #{path}"
      end
    end
    assert_equal 0, [ HourEntry.where(source: "adjustment").count, CoinTransaction.where(kind: "adjustment").count, UserNote.count, AdminAuditEvent.count ].sum
  end


  test "signed-out visitors and non-admins get a 404 on the list and a person's page" do
    get admin_users_path
    assert_response :not_found
    get admin_user_path(@teen)
    assert_response :not_found
    sign_in_as @staff
    get admin_users_path
    assert_response :not_found
    get admin_user_path(@teen)
    assert_response :not_found
    assert_equal 0, AdminAuditEvent.count, "a refused request leaves no trace"
  end

  test "the list shows names and statuses but never an email, a Slack id or a Hack Club Auth id" do
    give_coins(@teen, 40)
    code(@teen, Date.new(2026, 11, 10), 5400)
    as_admin(@staff)
    get admin_users_path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only"
    assert_select "title", "Admin users - BattleTown"
    assert_select "h1", 1
    assert_select "tbody tr", 2
    assert_select "#user-#{@teen.id}" do
      assert_select "th a[href=?]", admin_user_path(@teen), text: "Zed Teenager"
      assert_select "td", text: /Verified/
      assert_select "td", text: /YSWS eligible/
      assert_select "td.num", text: "40"
      assert_select "td.num", text: "1 h 30 min"
      assert_select "td", text: "10 Nov 2026"
    end
    [ @teen.email, @teen.slack_id, @teen.hca_uid, @staff.email, @staff.slack_id.to_s, @staff.hca_uid ].reject(&:blank?).each do |secret|
      assert_not_includes response.body, secret
    end
    assert_select "#total-users", "2"
    assert_select ".table-wrap[tabindex='0'][role=region][aria-label]"
  end

  test "search by name, Slack id, Hack Club Auth id and email finds the person and still lists no personal ids" do
    as_admin(@staff)
    { { by: "name", q: "zed tee" } => 1, { by: "slack_id", q: "U0ZEDTEEN" } => 1, { by: "hca_uid", q: @teen.hca_uid } => 1,
      { by: "email", q: "ZED.TEEN@example.test" } => 1, { by: "email", q: "zed" } => 0, { by: "name", q: "nobody" } => 0 }.each do |params, count|
      get admin_users_path(params)
      assert_response :success
      assert_select "tbody tr", count, params.inspect
      assert_not_includes response.body.sub(/value="[^"]*"/, ""), "zed.teen@example.test" if params[:by] == "email"
    end
    get admin_users_path(by: "name", q: "nobody")
    assert_select ".alert", "No one matches that search."
  end

  test "the search text never reaches the request log or the SQL log, and the page keeps no copy of it" do
    as_admin(@staff)
    log = query_log do
      get admin_users_path(by: "email", q: "zed.teen@example.test")
      get admin_users_path(by: "slack_id", q: "U0ZEDTEEN")
      get admin_users_path(by: "hca_uid", q: @teen.hca_uid)
      get admin_users_path(by: "name", q: "Zed Teenager")
      get admin_user_path(@teen)
    end
    assert_includes log, "Parameters:", "the log was captured"
    assert_includes log, "SELECT", "SQL was captured at debug level"
    [ "zed.teen@example.test", "U0ZEDTEEN", @teen.hca_uid, "Zed Teenager", "Zed Teen" ].each do |text|
      assert_not_includes log, text, "#{text} must not be in the log"
    end
    assert_includes log, "[FILTERED]"
  end

  test "filters and sorting work through the page and survive paging" do
    60.times { |i| User.create!(hca_uid: "ident!bulk-#{i}", display_name: "Bulk #{i}", time_zone: "UTC") }
    as_admin(@staff)
    get admin_users_path(onboarded: "yes", verified: "yes", eligible: "yes", referral: "haven", from: "2026-01-01", to: "2026-12-31", sort: "name")
    assert_response :success
    assert_select "tbody tr", 1
    assert_select "#total-users", "1"
    get admin_users_path(sort: "name")
    assert_select "tbody tr", 50
    assert_select "#total-users", "62"
    assert_select "nav.admin-pager a[rel=next][href=?]", "/admin/users?page=2&sort=name"
    get admin_users_path(sort: "name", page: 2)
    assert_select "tbody tr", 12
    assert_select "nav.admin-pager", /Page 2 of 2/
    get admin_users_path(page: 9999)
    assert_select "nav.admin-pager", /Page 2 of 2/
  end

  test "odd parameters are just ignored" do
    as_admin(@staff)
    [ { q: "x" * 10_000 }, { q: "'; DROP TABLE users; --", by: "email" }, { sort: "../../x", page: "NaN" }, { from: "garbage", to: "9999-99-99" },
      { onboarded: [ "yes" ] }, { q: { a: 1 } }, { by: [ "x" ] }, { q: "\u0000" }, { referral: "%" } ].each do |params|
      get admin_users_path(params)
      assert_response :success, params.inspect
    end
    assert User.exists?(@teen.id)
  end

  test "the list is the same handful of queries for 5 and for 50 people" do
    as_admin(@staff)
    get admin_users_path # warm up
    count = lambda do
      queries = 0
      subscriber = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get admin_users_path }
      queries
    end
    5.times { |i| User.create!(hca_uid: "ident!few-#{i}", display_name: "Few #{i}", time_zone: "UTC") }
    few = count.call
    45.times do |i|
      user = User.create!(hca_uid: "ident!lots-#{i}", display_name: "Lots #{i}", time_zone: "UTC")
      give_coins(user, 3)
      code(user, Date.new(2026, 11, 10), 600)
    end
    assert_equal few, count.call
  end

  # --- one person ---

  def busy_teen
    give_coins(@teen, 200)
    verified!(@teen)
    @project = make_project(@teen)
    code(@teen, Date.new(2026, 11, 8), HOUR)
    code(@teen, Date.new(2026, 11, 10), 1800)
    @ship = submit_ship(@project)
    @order = buy(@teen, "keychain")
    DailyResult.create!(user: @teen, local_date: Date.new(2026, 11, 9), raw_seconds: 900, quick_met: true, goal_met: false, streak_15: 3, goal_streak: 0, freeze_available: true, bonus_bps: 800)
    Notification.create!(user: @teen, kind: "daily_reminder", status: "sent", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "p-#{@teen.id}-1")
    Notification.create!(user: @teen, kind: "ship_approved", status: "failed", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "p-#{@teen.id}-2", subject_id: @ship.id)
    HackatimeConnection.create!(user: @teen, hackatime_uid: "99", access_token: "SECRET-ACCESS-TOKEN", refresh_token: "SECRET-REFRESH-TOKEN", scopes: "profile read",
                                connected_at: Time.current, last_synced_at: Time.utc(2026, 11, 12, 9, 30))
  end

  test "a person's page shows what staff need and nothing secret" do
    busy_teen
    as_admin(@staff)
    get admin_user_path(@teen)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "h1", "Zed Teenager"
    assert_select "dt", "Email"
    assert_select "dd", "zed.teen@example.test"
    assert_select "dd", "U0ZEDTEEN"
    assert_select "dd", @teen.hca_uid
    assert_select "dd", text: /Verified/
    assert_select "dd", text: /Connected.*last sync 12 Nov 2026 09:30 UTC/m
    assert_select "dd", "UTC"
    assert_select "dd", "haven"
    assert_select "dd", /Finished 2 Nov 2026/
    assert_select "#coin-balance", "170"

    assert_select "table[aria-label], caption", text: /Projects with their ships/
    assert_select "th", "Space Farm"
    assert_select "a[href=?]", admin_ship_path(@ship), text: "Open"
    assert_select "td", text: /1.5 hours coded/
    assert_select "caption", /Latest 50 coin entries/
    assert_select "tbody th", text: "Purchase"
    assert_select "td.num", text: "-30" if Prize.find("keychain").coins == 30
    assert_select "caption", /Coded time on each local date/
    assert_select "th", "Tue 10 Nov"
    assert_select "td", text: "30 min"
    assert_select "td", text: "1 h 00 min"
    assert_select "td", text: "Settled"
    assert_select "th", text: "Keychain" if Prize.find("keychain").name == "Keychain"
    assert_select "a[href=?]", admin_orders_path
    assert_select "dd", /3 days/
    assert_select "caption", /Messages by kind and state \(counts only\)/
    assert_select "tr", text: /Daily reminder\s*Sent\s*1/
    assert_select "tr", text: /Ship approved\s*Failed\s*1/

    assert_not_includes response.body, "SECRET-ACCESS-TOKEN"
    assert_not_includes response.body, "SECRET-REFRESH-TOKEN"
    assert_select "[style]", 0
  end

  test "verification and eligibility are shown, never editable" do
    as_admin(@staff)
    get admin_user_path(@teen)
    assert_select "input[name*=verification], select[name*=verification], input[name*=ysws], input[name*=eligible]", 0
    assert_select "small", text: /from Hack Club Auth, read-only/, minimum: 2
    %w[patch put delete].each do |verb|
      process(verb.to_sym, admin_user_path(@teen), params: { user: { verification_status: "verified", ysws_eligible: "1" } })
      assert_response :not_found
    end
    process(:post, admin_users_path, params: { user: { display_name: "x" } })
    assert_response :not_found
    assert_equal "verified", @teen.reload.verification_status
  end

  test "an unknown, huge or malformed id is a 404 and writes nothing" do
    as_admin(@staff)
    [ 0, 999_999, "99999999999999999999", "abc", "1.5", "-1" ].each do |id|
      get "/admin/users/#{id}"
      assert_response :not_found, id.inspect
    end
    assert_equal 0, AdminAuditEvent.count
  end

  test "opening a person is audited once per staff member and person in ten minutes" do
    as_admin(@staff)
    assert_difference -> { AdminAuditEvent.count }, 1 do
      get admin_user_path(@teen)
      get admin_user_path(@teen)
    end
    event = AdminAuditEvent.sole
    assert_equal [ @staff.id, "user_viewed", "User", @teen.id, {} ], [ event.actor_id, event.action, event.subject_type, event.subject_id, event.metadata ]
    travel 9.minutes
    assert_no_difference -> { AdminAuditEvent.count } do
      get admin_user_path(@teen)
    end
    travel 2.minutes
    assert_difference -> { AdminAuditEvent.count }, 1 do
      get admin_user_path(@teen)
    end
    assert_no_difference -> { AdminAuditEvent.count } do
      get admin_users_path
    end
  end

  test "the audit trail section of a person's page lists the events about them, not about others" do
    other = User.create!(hca_uid: "ident!other-person", display_name: "Other Person", time_zone: "UTC")
    AdminAudit.record!(actor: @staff, action: "user_viewed", subject: other)
    as_admin(@staff)
    get admin_user_path(@teen)
    assert_select "caption", /Latest 30 events about this person/
    assert_select "tr", text: /User viewed/, count: 1
    get admin_user_path(other)
    assert_select "tr", text: /User viewed/, count: 1
  end

  test "flag-guarded facts appear only while their flag is on, and flagged tables are not read while off" do
    Team.create!(name: "Crew X", invite_token: Team.new_token, invite_expires_at: 1.day.from_now).then { |crew| TeamMembership.create!(team: crew, user: @teen, joined_at: Time.current) }
    NpsResponse.create!(user: @teen, score: 9, comment: "private words", answered_at: Time.current, prompt_window_date: Date.new(2026, 11, 9))
    PlinkoDrop.create!(user: @teen, dropped_at: Time.current, local_date: Date.new(2026, 11, 9), slot: 4, points: 50, seed: 1, idempotency_key: "p-#{@teen.id}")
    as_admin(@staff)

    sql = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { sql << payload[:sql] }, "sql.active_record") { get admin_user_path(@teen) }
    assert_select "dt", text: "Crew member", count: 0
    assert_select "dt", text: "Survey answers", count: 0
    assert_select "dt", text: "Plinko balls dropped", count: 0
    flagged = %w[team_memberships teams nps_responses plinko_drops plinko_players]
    assert_empty sql.select { |statement| flagged.any? { |table| statement.match?(/\b(FROM|JOIN)\s+"#{table}"/i) } }

    %i[team nps plinko].each { |name| Flipper.enable(name) }
    get admin_user_path(@teen)
    assert_select "dt", "Crew member"
    assert_select "dd", "yes"
    assert_select "dt", "Survey answers"
    assert_select "dt", "Plinko balls dropped"
    assert_not_includes response.body, "private words"
    assert_not_includes response.body, "Crew X"
  end

  test "a person's page costs the same handful of queries however much they have done" do
    as_admin(@staff)
    count = lambda do
      queries = 0
      subscriber = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      travel 11.minutes # every measurement audits the view, so each pays for the same queries
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get admin_user_path(@teen) }
      queries
    end
    get admin_user_path(@teen)
    give_coins(@teen, 100)
    make_project(@teen, name: "One")
    few = count.call
    8.times do |i|
      make_project(@teen, name: "Extra #{i}", hackatime: nil)
      give_coins(@teen, 1)
      HourEntry.create!(user: @teen, local_date: Date.new(2026, 11, 1) + i, seconds: 300, source: "manual", note: "t", idempotency_key: "q-#{i}")
      buy(@teen, "keychain") if i < 2
    end
    Notification.create!(user: @teen, kind: "daily_reminder", status: "sent", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "q-n")
    assert_operator count.call, :<=, few + 1, "the page does not grow a query per project, ledger entry or order"
  end

  test "someone who is signed in as a person and an admin sees their own page with the adjust links replaced by a note" do
    as_admin(@staff)
    get admin_user_path(@staff)
    assert_response :success
    assert_select ".alert", /This is your own account/
    assert_select "a", text: "Adjust hours", count: 0
    get admin_user_path(@teen)
    assert_select "a[href=?]", new_admin_user_hours_adjustment_path(@teen), text: "Adjust hours"
    assert_select "a[href=?]", new_admin_user_coin_adjustment_path(@teen), text: "Adjust coins"
  end

  test "the people link is on the admin dashboard under People" do
    as_admin(@staff)
    get admin_root_path
    assert_select "h2", "People"
  end

  # --- notes ---

  test "a staff note is appended, shown on the page, audited without its text, and cannot be changed" do
    as_admin(@staff)
    assert_difference -> { UserNote.count }, 1 do
      post admin_user_notes_path(@teen), params: { note: "Wrote to them about missing hours." }
    end
    assert_redirected_to admin_user_path(@teen, anchor: "notes")
    follow_redirect!
    assert_select ".admin-notes__item", /Wrote to them about missing hours\./
    assert_select ".admin-notes__item .small", /Veteran, \d+ \w+ 2026/
    event = AdminAuditEvent.where(action: "user_note_added").sole
    assert_equal({ "note_id" => UserNote.sole.id }, event.metadata)
    assert_not_includes event.attributes.values.join(" "), "missing hours"

    note = UserNote.sole
    assert_raises(ActiveRecord::ReadOnlyRecord) { note.update!(body: "Edited") }
    %w[patch put delete].each do |verb|
      process(verb.to_sym, "/admin/users/#{@teen.id}/notes/#{note.id}")
      assert_response :not_found
    end
    assert_equal "Wrote to them about missing hours.", note.reload.body
  end

  test "a note that is empty or too long is refused with a message and nothing is written" do
    as_admin(@staff)
    [ "", "   ", "x" * 501 ].each do |body|
      assert_no_difference [ -> { UserNote.count }, -> { AdminAuditEvent.count } ] do
        post admin_user_notes_path(@teen), params: { note: body }
      end
      assert_redirected_to admin_user_path(@teen, anchor: "notes")
      follow_redirect!
      assert_select ".flash--alert", /The note/
    end
    post admin_user_notes_path(@teen), params: { note: "x" * 500 }
    assert_equal 1, UserNote.count
  end

  test "a note about an unknown person is a 404" do
    as_admin(@staff)
    post admin_user_notes_path(999_999), params: { note: "hello there" }
    assert_response :not_found
    assert_equal 0, UserNote.count
  end

  test "notes are for staff only: no teen-facing page shows them" do
    AdminUsers::AddNote.call(staff: @staff, user: @teen, body: "STAFF-ONLY-NOTE-TEXT")
    sign_in_as @teen
    [ dashboard_path, projects_path, ships_path, shop_path, settings_notifications_path, privacy_path ].each do |path|
      get path
      assert_not_includes response.body, "STAFF-ONLY-NOTE-TEXT", path
    end
  end

  # --- hours adjustment flow ---

  def hours_form(**overrides)
    { direction: "add", date: "2026-11-10", minutes: "30", reason: "Hackatime missed a session", token: AdminUsers::Adjustment.new_token }.merge(overrides)
  end

  test "hours: form, a wrong entry with a friendly message, then a right one with a confirm step" do
    as_admin(@staff)
    get new_admin_user_hours_adjustment_path(@teen)
    assert_response :success
    assert_select "form[action=?]", confirm_admin_user_hours_adjustment_path(@teen)
    assert_select "input[name=token][type=hidden]" do |fields|
      assert_match(/\A[0-9a-f]{32}\z/, fields.first["value"])
    end
    assert_select "textarea[name=reason][required][minlength='5'][maxlength='200']"
    assert_select "input[name=minutes][max='1440']"

    # wrong: too many minutes and a too-short reason
    post confirm_admin_user_hours_adjustment_path(@teen), params: hours_form(minutes: "5000", reason: "no")
    assert_response :unprocessable_content
    assert_select ".alert--danger", /Nothing was changed/
    assert_select ".alert--danger li", /Minutes must be a whole number from 1 to 1,440/
    assert_select ".alert--danger li", /Reason must be 5 to 200 characters/
    assert_select "textarea[name=reason]", "no"
    assert_equal 0, HourEntry.where(source: "adjustment").count

    # right: the confirm step shows the effect and writes nothing yet
    form = hours_form
    post confirm_admin_user_hours_adjustment_path(@teen), params: form
    assert_response :success
    assert_select "h1", "Confirm the hours change"
    assert_select "dd", /Add 30 min/
    assert_select "dd", /0 min now, 30 min after/
    assert_select "dd", "Hackatime missed a session"
    assert_select "input[name=confirmed][value='1']"
    assert_equal 0, HourEntry.where(source: "adjustment").count
    assert_equal 0, AdminAuditEvent.where(action: "hours_adjusted").count

    post admin_user_hours_adjustment_path(@teen), params: form.merge(confirmed: "1")
    assert_redirected_to admin_user_path(@teen)
    follow_redirect!
    assert_select ".flash--notice", /Hours adjusted/
    entry = HourEntry.find_by!(user_id: @teen.id, source: "adjustment")
    assert_equal [ 1800, Date.new(2026, 11, 10), "admin:#{@staff.id}" ], [ entry.seconds, entry.local_date, entry.created_by ]
    assert_select "tr", text: /Tue 10 Nov\s*30 min\s*30 min/
    assert_select "tr", text: /Hours adjusted/
    assert_select "tr", text: /seconds: 1800/
  end

  # Turbo Drive ignores a form response that is neither a redirect nor an error (the confirm page is a plain 200 answer to a POST),
  # so these forms opt out and the browser does an ordinary full-page post. Caught in the real-browser walk, invisible to a request test.
  test "the adjustment forms that answer with a page rather than a redirect opt out of Turbo" do
    as_admin(@staff)
    get new_admin_user_hours_adjustment_path(@teen)
    assert_select "form[action=?][data-turbo=false]", confirm_admin_user_hours_adjustment_path(@teen)
    get new_admin_user_coin_adjustment_path(@teen)
    assert_select "form[action=?][data-turbo=false]", confirm_admin_user_coin_adjustment_path(@teen)
    post confirm_admin_user_hours_adjustment_path(@teen), params: hours_form
    assert_select "form[action=?][data-turbo=false]", admin_user_hours_adjustment_path(@teen)
    post confirm_admin_user_coin_adjustment_path(@teen), params: coins_form
    assert_select "form[action=?][data-turbo=false]", admin_user_coin_adjustment_path(@teen)
  end

  test "hours: a double submit with the same token changes the ledger once" do
    as_admin(@staff)
    form = hours_form.merge(confirmed: "1")
    2.times { post admin_user_hours_adjustment_path(@teen), params: form }
    follow_redirect!
    assert_select ".flash--notice", /already been applied/
    assert_equal 1, HourEntry.where(source: "adjustment").count
    assert_equal 1, AdminAuditEvent.where(action: "hours_adjusted").count
  end

  test "hours: posting straight to the write without the confirm step shows the confirm step instead" do
    as_admin(@staff)
    post admin_user_hours_adjustment_path(@teen), params: hours_form
    assert_response :success
    assert_select "h1", "Confirm the hours change"
    assert_equal 0, HourEntry.where(source: "adjustment").count
  end

  test "hours: the confirm step warns about a settled day and a day past the daily limit" do
    DailyResult.create!(user: @teen, local_date: Date.new(2026, 11, 10), raw_seconds: 0, quick_met: false, goal_met: false, streak_15: 0, goal_streak: 0, freeze_available: true)
    code(@teen, Date.new(2026, 11, 10), 43_200)
    as_admin(@staff)
    post confirm_admin_user_hours_adjustment_path(@teen), params: hours_form(minutes: "60")
    assert_select ".alert--warning", /That day has already settled/
    assert_select ".alert--warning", /Past the daily limit/
  end

  test "hours: taking time off a day that does not have it is refused" do
    as_admin(@staff)
    post confirm_admin_user_hours_adjustment_path(@teen), params: hours_form(direction: "subtract")
    assert_response :unprocessable_content
    assert_select ".alert--danger li", /more than the 0 minutes recorded/
  end

  test "hours: staff cannot adjust their own, in the form, the confirm step or the write" do
    as_admin(@staff)
    get new_admin_user_hours_adjustment_path(@staff)
    assert_select ".alert", /This is your own account/
    assert_select "form[action*=confirm]", 0
    post confirm_admin_user_hours_adjustment_path(@staff), params: hours_form
    assert_response :unprocessable_content
    assert_select ".alert--danger li", /can't change your own hours or coins/
    post admin_user_hours_adjustment_path(@staff), params: hours_form.merge(confirmed: "1")
    assert_response :unprocessable_content
    assert_equal 0, HourEntry.where(user_id: @staff.id, source: "adjustment").count
    assert_equal 0, AdminAuditEvent.where(action: "hours_adjusted").count
  end

  test "hours: junk input never raises" do
    as_admin(@staff)
    [ { date: "'; DROP TABLE users;--" }, { minutes: "9" * 400 }, { reason: "é" * 5000 }, { token: "x" * 9000 }, { direction: [ "add" ] }, { date: { a: 1 } } ].each do |junk|
      post confirm_admin_user_hours_adjustment_path(@teen), params: hours_form.merge(junk)
      assert_includes [ 200, 422 ], response.status, junk.inspect
      post admin_user_hours_adjustment_path(@teen), params: hours_form.merge(junk).merge(confirmed: "1")
      assert_includes [ 200, 303, 422 ], response.status, junk.inspect
    end
    assert User.exists?(@teen.id)
  end

  # --- coin adjustment flow ---

  def coins_form(**overrides)
    { direction: "add", coins: "25", reason: "Missing ship payout", token: AdminUsers::Adjustment.new_token }.merge(overrides)
  end

  test "coins: a wrong entry, then a right one through the confirm step" do
    give_coins(@teen, 10)
    as_admin(@staff)
    get new_admin_user_coin_adjustment_path(@teen)
    assert_response :success
    assert_select "strong", "10"

    post confirm_admin_user_coin_adjustment_path(@teen), params: coins_form(direction: "subtract", coins: "11")
    assert_response :unprocessable_content
    assert_select ".alert--danger li", /below zero \(it is 10 now\)/
    post confirm_admin_user_coin_adjustment_path(@teen), params: coins_form(coins: "501")
    assert_select ".alert--danger li", /from 1 to 500/

    form = coins_form(direction: "subtract", coins: "4")
    post confirm_admin_user_coin_adjustment_path(@teen), params: form
    assert_response :success
    assert_select "dd", /Take off 4 coins/
    assert_select "dd", /10 now, 6 after/
    assert_equal 10, Coins::Balance.total(@teen)

    post admin_user_coin_adjustment_path(@teen), params: form.merge(confirmed: "1")
    assert_redirected_to admin_user_path(@teen)
    follow_redirect!
    assert_select "#coin-balance", "6"
    assert_select "tr", text: /Adjustment\s*-4\s*Missing ship payout\s*admin:#{@staff.id}/
    assert_equal 6, Coins::Balance.total(@teen)
  end

  test "coins: a double submit changes the balance once" do
    as_admin(@staff)
    form = coins_form.merge(confirmed: "1")
    2.times { post admin_user_coin_adjustment_path(@teen), params: form }
    assert_equal 25, Coins::Balance.total(@teen)
    assert_equal 1, AdminAuditEvent.where(action: "coins_adjusted").count
  end

  test "coins: staff cannot adjust their own" do
    as_admin(@staff)
    get new_admin_user_coin_adjustment_path(@staff)
    assert_select ".alert", /This is your own account/
    post admin_user_coin_adjustment_path(@staff), params: coins_form.merge(confirmed: "1")
    assert_response :unprocessable_content
    assert_equal 0, Coins::Balance.total(@staff)
  end

  test "an adjustment for an unknown person is a 404" do
    as_admin(@staff)
    get new_admin_user_coin_adjustment_path(999_999)
    assert_response :not_found
    post admin_user_coin_adjustment_path(999_999), params: coins_form.merge(confirmed: "1")
    assert_response :not_found
    post admin_user_hours_adjustment_path(999_999), params: hours_form.merge(confirmed: "1")
    assert_response :not_found
  end

  test "non-admins cannot adjust anything, and nothing changes" do
    sign_in_as @teen
    post admin_user_coin_adjustment_path(@staff), params: coins_form.merge(confirmed: "1")
    assert_response :not_found
    post admin_user_hours_adjustment_path(@staff), params: hours_form.merge(confirmed: "1")
    assert_response :not_found
    post admin_user_notes_path(@staff), params: { note: "hello there" }
    assert_response :not_found
    assert_equal [ 0, 0, 0, 0 ], [ CoinTransaction.where(kind: "adjustment").count, HourEntry.where(source: "adjustment").count, UserNote.count, AdminAuditEvent.count ]
  end

  # --- CSRF and logs ---

  test "every write needs a CSRF token" do
    as_admin(@staff)
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    begin
      [ [ confirm_admin_user_hours_adjustment_path(@teen), hours_form ], [ admin_user_hours_adjustment_path(@teen), hours_form.merge(confirmed: "1") ],
        [ confirm_admin_user_coin_adjustment_path(@teen), coins_form ], [ admin_user_coin_adjustment_path(@teen), coins_form.merge(confirmed: "1") ],
        [ admin_user_notes_path(@teen), { note: "a note here" } ] ].each do |path, params|
        post path, params: params
        assert_response :unprocessable_content, path
      end
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
    assert_equal [ 0, 0, 0 ], [ CoinTransaction.where(kind: "adjustment").count, HourEntry.where(source: "adjustment").count, UserNote.count ]
  end

  test "reasons, notes and tokens are filtered from the request log and no email reaches any log" do
    as_admin(@staff)
    log = query_log do
      post admin_user_hours_adjustment_path(@teen), params: hours_form(reason: "SECRET-REASON-TEXT", token: "a" * 32).merge(confirmed: "1")
      post admin_user_notes_path(@teen), params: { note: "SECRET-NOTE-TEXT" }
      get admin_user_path(@teen)
    end
    [ "SECRET-REASON-TEXT", "SECRET-NOTE-TEXT", "a" * 32, "zed.teen@example.test", "U0ZEDTEEN" ].each do |text|
      assert_not_includes log, text
    end
  end
end
