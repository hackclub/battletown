require "test_helper"
require_relative "../support/ships_test_support"

class AdminShipsTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }
  NOW = Time.utc(2026, 11, 10, 12)

  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false

    @admin = users(:onboarded)
    @teen = users(:new_user)
    @teen.update_columns(display_name: "Casey Teen", email: "casey@example.com", slack_id: "U0CASEY", created_at: Time.utc(2026, 11, 1, 12),
                         onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
    @project = make_project(@teen, name: "Cow Game")
    (7..9).each { |day| code(@teen, D[day], HOUR) }
    @ship = submit_ship(@project, demo_url: "https://play.example.com/cows")
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def make_admin(user) = ENV["ADMIN_HCA_UIDS"] = user.hca_uid

  def sign_in_admin
    make_admin(@admin)
    sign_in_as @admin
  end

  def second_ship
    other = make_project(@teen, name: "Website", hackatime: "website")
    code(@teen, D[9], HOUR, hackatime: "website")
    submit_ship(other)
  end

  # --- access ---

  test "signed-out visitors get a 404 on every ships route and nothing changes" do
    [ "/admin/ships", "/admin/ships/#{@ship.id}" ].each do |path|
      get path
      assert_response :not_found
    end
    patch "/admin/ships/#{@ship.id}/approve"
    assert_response :not_found
    patch "/admin/ships/#{@ship.id}/reject", params: { reason_note: "no" }
    assert_response :not_found
    assert_equal "submitted", @ship.reload.status
    assert_equal 0, CoinTransaction.count
  end

  test "non-admins get the same 404 and cannot decide a ship, including the ship's own owner" do
    make_admin(users(:onboarded))
    [ @teen ].each do |user|
      sign_in_as user
      missing = (get("/definitely-not-a-page") && response.body)
      get "/admin/ships"
      assert_response :not_found
      assert_equal missing, response.body
      get "/admin/ships/#{@ship.id}"
      assert_response :not_found
      patch "/admin/ships/#{@ship.id}/approve"
      assert_response :not_found
      patch "/admin/ships/#{@ship.id}/reject", params: { reason_note: "no" }
      assert_response :not_found
    end
    assert_equal "submitted", @ship.reload.status
    assert_equal 0, CoinTransaction.count
  end

  test "drafts are never listed or shown to staff" do
    draft_project = make_project(@teen, name: "Draft thing", hackatime: "draft-thing")
    code(@teen, D[9], HOUR, hackatime: "draft-thing")
    draft = submit_ship(draft_project, submit: false)
    sign_in_admin
    get "/admin/ships"
    assert_not_includes response.body, "Draft thing"
    get "/admin/ships/#{draft.id}"
    assert_response :not_found
    patch "/admin/ships/#{draft.id}/approve"
    assert_response :not_found
    assert_equal "draft", draft.reload.status
  end

  # --- the queue ---

  test "the queue lists waiting ships first, oldest first, with a status filter and counts, in orange admin UI with no email" do
    @ship.update_columns(submitted_at: 1.day.ago)
    older = second_ship.tap { |ship| ship.update_columns(submitted_at: 3.days.ago) }
    done_project = make_project(@teen, name: "Finished thing", hackatime: "finished")
    code(@teen, D[9], HOUR, hackatime: "finished")
    done = submit_ship(done_project).tap { |ship| ship.update_columns(status: "rejected", rejection_reason: "x", reviewed_at: Time.current, submitted_at: 6.days.ago) }
    sign_in_admin

    get "/admin/ships"
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only h1", "Ship review queue"
    assert_select "tbody tr th", text: "Casey Teen"
    assert_equal [ "Website", "Cow Game", "Finished thing" ], css_select("tbody tr td:nth-child(2)").map(&:text)
    assert_select "a[href=?]", "/admin/ships/#{older.id}", text: "Review"
    assert_select "a[href=?]", "/admin/ships/#{done.id}", text: "View"
    assert_select ".admin-filter", text: "All (3)"
    assert_select ".admin-filter", text: "Waiting (2)"
    assert_not_includes response.body, "casey@example.com"
    assert_not_includes response.body, "U0CASEY"

    get "/admin/ships", params: { status: "rejected" }
    assert_select "tbody tr", 1
    assert_select ".admin-filter--current", text: "Rejected (1)"
    get "/admin/ships", params: { status: "bogus" }
    assert_select "tbody tr", 3
  end

  test "the admin dashboard links to the queue with the waiting count" do
    sign_in_admin
    get "/admin"
    assert_select ".admin-only a[href='/admin/ships']", "Ship review queue"
    assert_select ".admin-only", text: /\(1 waiting\)/
  end

  # --- one ship ---

  test "a ship page shows the teen, verification, project, links, window, hours, streak context and other ships" do
    DailyResult.create!(user: @teen, local_date: D[8], raw_seconds: 3600, quick_met: true, goal_met: true, streak_15: 8, goal_streak: 8,
                        freeze_available: true, bonus_bps: 1500)
    previous = make_project(@teen, name: "Old thing", hackatime: "old-thing")
    code(@teen, D[3], HOUR, hackatime: "old-thing")
    old = submit_ship(previous).tap { |ship| ship.update_columns(status: "approved", approved_seconds: HOUR, reviewed_at: Time.current) }
    sign_in_admin

    travel_to(NOW) { get "/admin/ships/#{@ship.id}" }
    assert_response :success
    assert_select ".admin-only h1", "Review: Cow Game"
    assert_select ".admin-dl", text: /Casey Teen/
    assert_select ".admin-dl", text: /Needs submission/
    assert_select ".admin-dl", text: /coins stay locked until verified/
    assert_select ".admin-dl a[href=?]", REPO
    assert_select ".admin-dl a[href=?]", "https://play.example.com/cows"
    assert_select ".admin-dl", text: /space-farm/
    assert_select ".admin-dl", text: /3 hours/
    assert_select ".admin-dl", text: /Nov 7 to Nov 9/
    assert_select ".admin-panel", text: /8-day streak, 15% bonus, freeze available/
    assert_select "caption", text: "This teen's other ships"
    assert_select "a[href=?]", "/admin/ships/#{old.id}"
    assert_select ".admin-warning", 0
    assert_select "form[action=?] input[type=submit][value=Approve]", "/admin/ships/#{@ship.id}/approve"
    assert_select "form[action=?] select[name=reason_preset] option", "/admin/ships/#{@ship.id}/reject", minimum: 5
    assert_not_includes response.body, "casey@example.com"
    assert_not_includes response.body, "U0CASEY"
  end

  test "a ship page warns when some streak days are not final yet and offers Approve anyway" do
    sign_in_admin
    travel_to(Time.utc(2026, 11, 9, 12)) { get "/admin/ships/#{@ship.id}" } # Nov 9 settles on Nov 10 at 06:00
    assert_select ".admin-warning", text: /Bonus coins for Nov 9 will not be included/
    assert_select "input[type=submit][value='Approve anyway']"
  end

  # --- deciding ---

  test "approving with the default hours credits the coins once and shows the result" do
    sign_in_admin
    travel_to(NOW) { patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "" } }
    assert_redirected_to "/admin/ships/#{@ship.id}"
    follow_redirect!
    assert_select ".flash--notice", text: /Approved\. Credited 30 coins plus 2 streak bonus coins/
    @ship.reload
    assert_equal "approved", @ship.status
    assert_equal 3 * HOUR, @ship.approved_seconds
    assert_equal @admin, @ship.reviewer
    assert_equal({ base: 30, bonus: 2, total: 32 }, @ship.coin_breakdown)
    assert_equal 32, Coins::Balance.total(@teen)
    assert_select ".admin-dl", text: /30 base \+ 2 streak bonus = 32 coins/
    assert_select "form[action$='/approve']", 0
  end

  test "approving twice (a double click) credits once" do
    sign_in_admin
    travel_to(NOW) do
      patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "" }
      patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "" }
    end
    assert_redirected_to "/admin/ships/#{@ship.id}"
    follow_redirect!
    assert_select ".flash--alert", text: /no longer waiting/
    assert_equal 2, CoinTransaction.where(user_id: @teen.id).count
    assert_equal 32, Coins::Balance.total(@teen)
  end

  test "approved hours can be lowered in steps but never raised, and bad values change nothing" do
    sign_in_admin
    [ "3.5", "0", "-1", "1.1", "lots" ].each do |text|
      travel_to(NOW) { patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: text } }
      assert_redirected_to "/admin/ships/#{@ship.id}"
      follow_redirect!
      assert_select ".flash--alert", minimum: 1
      assert_equal "submitted", @ship.reload.status, text
    end
    assert_equal 0, CoinTransaction.count

    travel_to(NOW) { patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "1.75" } }
    assert_equal 6300, @ship.reload.approved_seconds
  end

  test "approving while recent days are unsettled still credits and leaves a note on the ship" do
    sign_in_admin
    travel_to(Time.utc(2026, 11, 9, 12)) { patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "" } }
    @ship.reload
    assert_equal "approved", @ship.status
    assert_match(/2026-11-09/, @ship.payout_note)
    assert_equal 30, @ship.coin_breakdown[:base]
    follow_redirect!
    assert_select ".admin-dl", text: /Payout note/
  end

  test "an unverified teen's coins are credited by approval" do
    assert @teen.verification_needs_submission?
    sign_in_admin
    travel_to(NOW) { patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "" } }
    assert_operator Coins::Balance.total(@teen), :>, 0
  end

  test "approving a ship the teen withdrew changes nothing" do
    Ships::Withdraw.call(ship: @ship)
    sign_in_admin
    travel_to(NOW) { patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "" } }
    follow_redirect!
    assert_select ".flash--alert", text: /no longer waiting/
    assert_equal "withdrawn", @ship.reload.status
    assert_equal 0, CoinTransaction.count
  end

  test "rejecting with a preset and free text saves the reason, credits nothing and the teen can see it" do
    preset = Ships::Config.current.rejection_reasons.first
    sign_in_admin
    patch "/admin/ships/#{@ship.id}/reject", params: { reason_preset: preset, reason_note: "Make it public please." }
    assert_redirected_to "/admin/ships"
    @ship.reload
    assert_equal "rejected", @ship.status
    assert_equal "#{preset}: Make it public please.", @ship.rejection_reason
    assert_equal @admin, @ship.reviewer
    assert_equal 0, CoinTransaction.count

    follow_redirect!
    assert_select ".flash--notice", text: /rejected/
  end

  test "a rejection without a reason, or with one that is too long, is refused" do
    sign_in_admin
    patch "/admin/ships/#{@ship.id}/reject", params: { reason_preset: "", reason_note: "  " }
    follow_redirect!
    assert_select ".flash--alert", text: /Give a reason/
    patch "/admin/ships/#{@ship.id}/reject", params: { reason_note: "x" * 301 }
    follow_redirect!
    assert_select ".flash--alert", text: /up to 300 characters/
    assert_equal "submitted", @ship.reload.status
  end

  test "an admin who deleted their account leaves the ship with no reviewer, and the page still renders" do
    sign_in_admin
    travel_to(NOW) { patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "" } }
    @admin.delete
    @ship.reload
    assert_nil @ship.reviewer_id
    make_admin(@teen) # any admin can read it
    sign_in_as @teen
    get "/admin/ships/#{@ship.id}"
    assert_select ".admin-dl", text: /a former reviewer/
  end

  test "decisions do not write names, emails or ship text to the request log" do
    sign_in_admin
    io = StringIO.new
    old = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(io)
    begin
      travel_to(NOW) { patch "/admin/ships/#{@ship.id}/approve", params: { approved_hours: "" } }
      second_ship.then { |ship| patch "/admin/ships/#{ship.id}/reject", params: { reason_note: "UNIQUE-REASON-789" } }
    ensure
      ActionController::Base.logger = old
    end
    assert_includes io.string, "Parameters:"
    assert_not_includes io.string, "UNIQUE-REASON-789"
    assert_not_includes io.string, "Casey Teen"
    assert_not_includes io.string, "casey@example.com"
  end
end
