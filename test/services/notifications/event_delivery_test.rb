require "test_helper"
require_relative "../../support/notifications_helper"
require_relative "../../support/ships_test_support"
require_relative "../../support/coins_helper"

# Copy rendering and delivery of the event kinds (link question, ship reminders, ship decisions) through the real
# dispatcher with a fake adapter. No network, nothing real is sent.
class Notifications::EventDeliveryTest < ActiveSupport::TestCase
  include NotificationsHelper
  include ShipsTestSupport
  include CoinsHelper

  D = ->(day) { Date.new(2026, 11, day) }
  NOON = Time.utc(2026, 11, 10, 12)
  CONFIG = Notifications::Config.current
  APP = "https://battletown.example"

  setup do
    @user = create_user
    @project = make_project(@user)
    @reviewer = users(:onboarded)
  end

  def run_dispatcher(adapter, now: NOON + 1.minute, enabled: "true", config: CONFIG)
    with_env("NOTIFICATIONS_ENABLED" => enabled, "APP_URL" => APP) do
      Notifications::Dispatcher.run(now: now, adapter: adapter, config: config)
    end
  end

  def queue(kind, subject_id, key: "#{kind}:#{subject_id}", now: NOON)
    Notifications::Outbox.enqueue(user: @user, kind: kind, subject_id: subject_id, key: key, now: now)
  end

  def approved_ship(coded_hours: 3)
    coded_hours.times { |i| code(@user, D[7 + i], HOUR) }
    ship = submit_ship(@project)
    Ships::Approve.call(ship: ship, reviewer: @reviewer, approved_seconds: ship.coded_seconds, now: NOON)
    ship.reload
  end

  def text_for(row, user = @user)
    with_env("APP_URL" => APP) { Notifications::Message.build(row, user) }
  end

  # --- copy ---

  test "every event template is short, friendly and names Hack Club correctly" do
    Notification::EVENT_KINDS.each do |kind|
      template = CONFIG.template(kind)
      assert_operator template.length, :<=, 280, kind
      assert_no_match(/hackclub|HackClub|hack club/, template)
    end
  end

  test "link_question names both projects and links to the projects page" do
    suggestion = @project.link_suggestions.create!(hackatime_project: "space-farm-2")
    text = text_for(queue("link_question", suggestion.id))
    assert_includes text, "space-farm-2"
    assert_includes text, "Space Farm"
    assert_includes text, "#{APP}/projects"
  end

  test "ship_reminder and ship_mvp name the project, the hours and link to the ship form" do
    code(@user, D[7], 5 * HOUR)
    code(@user, D[8], 5 * HOUR)
    reminder = text_for(queue("ship_reminder", @project.id, key: "r"))
    mvp = text_for(queue("ship_mvp", @project.id, key: "m"))
    assert_includes reminder, "5 hours on Space Farm"
    assert_includes mvp, "10 hours on Space Farm"
    [ reminder, mvp ].each { |text| assert_includes text, "#{APP}/projects/#{@project.id}/ships/new" }
  end

  test "ship_approved gives the hours, the coins and the ship link; unverified people also get the unlock note" do
    ship = approved_ship
    @user.update_columns(verification_status: "needs_submission")
    text = text_for(queue("ship_approved", ship.id))
    assert_includes text, "approved for 3 hours"
    assert_includes text, "#{ship.coin_breakdown[:total]} coins"
    assert_includes text, "unlock when you verify your identity with Hack Club (https://auth.hackclub.com)"
    assert_includes text, "#{APP}/ships/#{ship.id}"

    @user.update_columns(verification_status: "verified")
    verified = text_for(Notification.find_by!(kind: "ship_approved"))
    assert_no_match(/unlock/, verified)
    assert_no_match(/\{|\}/, verified)
  end

  test "ship_rejected carries the reason and a link that pre-fills the fix" do
    code(@user, D[7], HOUR)
    ship = submit_ship(@project)
    Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "The demo link does not open")
    text = text_for(Notification.find_by!(kind: "ship_rejected"))
    assert_includes text, "The demo link does not open."
    assert_includes text, "#{APP}/projects/#{@project.id}/ships/new?from=#{ship.id}"
  end

  test "names and reasons are shortened and escaped so they cannot open a Slack mention or link" do
    @project.update!(name: "<!channel> & <https://evil.example|click>")
    code(@user, D[7], 5 * HOUR)
    text = text_for(queue("ship_reminder", @project.id))
    assert_includes text, "&lt;!channel&gt; &amp; &lt;https://evil.example|click&gt;"
    assert_no_match(/<!channel>|<https/, text)

    code(@user, D[8], HOUR)
    ship = submit_ship(@project)
    Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "x" * 300)
    long = text_for(Notification.find_by!(kind: "ship_rejected"))
    assert_operator long.length, :<, 560
  end

  test "a message whose subject is gone or no longer true has no text" do
    suggestion = @project.link_suggestions.create!(hackatime_project: "gone")
    row = queue("link_question", suggestion.id)
    suggestion.update!(state: "declined")
    assert_nil text_for(row)

    reminder = queue("ship_reminder", @project.id, key: "r")
    assert_nil text_for(reminder), "no coded time yet"

    assert_nil text_for(queue("ship_approved", 0, key: "a"))
    other = create_user
    code(@user, D[7], HOUR)
    ship = submit_ship(@project)
    Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "No.")
    assert_nil text_for(queue("ship_rejected", ship.id, key: "x"), other), "someone else's ship"
  end

  # --- delivery ---

  test "the dispatcher sends an event message once, with the built text, and does not queue a daily reminder for it" do
    suggestion = @project.link_suggestions.create!(hackatime_project: "space-farm-2")
    row = queue("link_question", suggestion.id)
    adapter = NotificationsHelper::FakeAdapter.new
    summary = run_dispatcher(adapter)
    run_dispatcher(adapter)

    assert_equal 1, summary.sent
    call = adapter.calls.sole
    assert_equal @user.slack_id, call[:slack_id]
    assert_includes call[:text], "space-farm-2"
    assert row.reload.sent?
    assert_equal 0, Notification.pending.where(user_id: @user.id).count
  end

  test "the kill switch off sends nothing and leaves the row waiting" do
    row = queue("ship_approved", approved_ship.id)
    [ nil, "false", "" ].each do |value|
      adapter = NotificationsHelper::FakeAdapter.new
      run_dispatcher(adapter, enabled: value)
      assert_empty adapter.calls
    end
    assert row.reload.pending?
  end

  test "someone who opts out after the row was queued gets nothing" do
    row = queue("ship_approved", approved_ship.id)
    Notifications::Preferences.update!(@user, "ship_approved" => "0")
    adapter = NotificationsHelper::FakeAdapter.new
    summary = run_dispatcher(adapter)

    assert_empty adapter.calls
    assert_equal 1, summary.cancelled
    assert_equal [ "cancelled", "opted_out" ], [ row.reload.status, row.last_error_code ]
  end

  test "opting out of the daily reminder after it was queued stops it and queues no new one" do
    daily = Notifications::Scheduler.schedule_next(@user, now: NOON)
    Notifications::Preferences.update!(@user, "daily_reminder" => "0")
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter, now: daily.due_at + 1.minute)

    assert_empty adapter.calls
    assert daily.reload.cancelled?
    assert_equal 0, Notification.pending.where(user_id: @user.id).count
  end

  test "a person who lost their Slack id after queueing gets nothing" do
    row = queue("ship_approved", approved_ship.id)
    @user.update_columns(slack_id: nil)
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert row.reload.cancelled?
  end

  test "quiet hours move an event message to the end of the person's quiet window" do
    row = queue("ship_approved", approved_ship.id, now: Time.utc(2026, 11, 10, 22, 30))
    adapter = NotificationsHelper::FakeAdapter.new
    summary = run_dispatcher(adapter, now: Time.utc(2026, 11, 10, 23, 0))
    assert_empty adapter.calls
    assert_equal 1, summary.deferred
    assert_equal Time.utc(2026, 11, 11, 7, 0), row.reload.due_at

    run_dispatcher(adapter, now: Time.utc(2026, 11, 11, 7, 1))
    assert_equal 1, adapter.calls.size
    assert row.reload.sent?
  end

  test "an event message older than the lateness limit is dropped, not sent" do
    row = queue("ship_approved", approved_ship.id, now: NOON - 3.days)
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert_equal [ "cancelled", "stale" ], [ row.reload.status, row.last_error_code ]
  end

  test "a reminder whose hours no longer count toward the project is dropped" do
    code(@user, D[7], 5 * HOUR)
    row = queue("ship_reminder", @project.id)
    @project.hackatime_links.destroy_all
    adapter = NotificationsHelper::FakeAdapter.new
    run_dispatcher(adapter)
    assert_empty adapter.calls
    assert_equal "subject_gone", row.reload.last_error_code
  end

  test "a failed event message is retried by the normal backoff and logs no personal data" do
    row = queue("ship_approved", approved_ship.id)
    adapter = NotificationsHelper::FakeAdapter.new(Notifications::Slack::Result.failure("ratelimited", retryable: true))
    logs = capture_logs { run_dispatcher(adapter) }
    assert row.reload.pending?
    assert_equal 1, row.attempts
    assert_no_match(/#{@user.slack_id}|coins|approved for|#{APP}/, logs)
  end

  test "event messages and their logs never contain the Slack id or the email" do
    suggestion = @project.link_suggestions.create!(hackatime_project: "space-farm-2")
    queue("link_question", suggestion.id)
    logs = capture_logs { run_dispatcher(NotificationsHelper::FakeAdapter.new) }
    assert_no_match(/#{@user.slack_id}/, logs)
    assert_equal 0, Notification.where(user_id: @user.id).where("idempotency_key ~ ?", "@").count
  end
end
