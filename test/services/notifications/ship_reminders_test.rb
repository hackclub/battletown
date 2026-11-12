require "test_helper"
require "rake"
require_relative "../../support/notifications_helper"
require_relative "../../support/ships_test_support"
require_relative "../../support/coins_helper"

class Notifications::ShipRemindersTest < ActiveSupport::TestCase
  include NotificationsHelper
  include ShipsTestSupport
  include CoinsHelper

  D = ->(day) { Date.new(2026, 11, day) }
  NOW = Time.utc(2026, 11, 10, 12)

  setup do
    @user = create_user
    @project = make_project(@user)
    @reviewer = users(:onboarded)
  end

  def scan(now: NOW) = Notifications::ShipReminders.scan(now: now)

  def rows = Notification.where(user_id: @user.id, kind: %w[ship_reminder ship_mvp]).order(:id)

  test "the thresholds come from game.yml: five and ten hours" do
    assert_equal [ 5 * HOUR, 10 * HOUR ], Ships::Config.current.reminder_seconds
  end

  test "below the first threshold nothing is queued" do
    code(@user, D[7], 5 * HOUR - 1)
    result = scan
    assert_equal 1, result.scanned
    assert_equal 0, result.queued
    assert_empty rows
  end

  test "five hours queues one ship_reminder, however often the scan runs" do
    code(@user, D[7], 3 * HOUR)
    code(@user, D[8], 2 * HOUR)
    assert_equal 1, scan.queued
    3.times { assert_equal 0, scan.queued }

    row = rows.sole
    assert_equal [ "ship_reminder", @project.id ], [ row.kind, row.subject_id ]
    assert_equal "ship_reminder:#{@project.id}:first:5", row.idempotency_key
    assert row.pending?
  end

  test "ten hours queues the MVP nudge as well, once" do
    code(@user, D[7], 5 * HOUR)
    scan
    code(@user, D[8], 5 * HOUR)
    assert_equal 1, scan.queued
    scan

    assert_equal %w[ship_reminder ship_mvp], rows.pluck(:kind)
    assert_equal "ship_mvp:#{@project.id}:first:10", rows.last.idempotency_key
  end

  test "someone who crossed both thresholds before the first scan gets only the MVP nudge" do
    code(@user, D[7], 6 * HOUR)
    code(@user, D[8], 6 * HOUR)
    scan
    assert_equal [ "ship_mvp" ], rows.pluck(:kind)
  end

  test "a pending lower reminder is cancelled when the higher threshold is queued" do
    code(@user, D[7], 5 * HOUR)
    scan
    reminder = rows.sole
    code(@user, D[8], 5 * HOUR)
    scan
    assert reminder.reload.cancelled?
    assert_equal [ "pending" ], rows.where(kind: "ship_mvp").pluck(:status)
  end

  test "a sent reminder is not cancelled or repeated by a later scan" do
    code(@user, D[7], 5 * HOUR)
    scan
    rows.sole.update!(status: "sent", sent_at: NOW)
    scan
    assert_equal 1, rows.count
    assert rows.sole.sent?
  end

  test "after a ship the next window starts fresh and fires again at the first threshold" do
    code(@user, D[7], 5 * HOUR)
    scan
    first = rows.sole
    ship = submit_ship(@project)
    assert first.reload.cancelled?, "shipping cancels the reminder that was waiting"

    code(@user, D[9], 4 * HOUR)
    scan
    assert_equal 1, rows.count, "four hours is below the threshold in the new window"

    code(@user, D[10], 1 * HOUR)
    assert_equal 1, scan.queued
    second = rows.last
    assert_equal "ship_reminder", second.kind
    assert_equal "ship_reminder:#{@project.id}:#{ship.window_end_date + 1}:5", second.idempotency_key
    assert_not_equal first.idempotency_key, second.idempotency_key
  end

  test "a rejected ship gives its window back without a repeat reminder" do
    code(@user, D[7], 5 * HOUR)
    scan
    ship = submit_ship(@project)
    Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "Please add a demo link.")
    scan
    assert_equal 1, rows.count, "same window, same key: no second message"
  end

  test "each project is counted on its own" do
    other = make_project(@user, name: "Other", hackatime: "other-hackatime")
    code(@user, D[7], 3 * HOUR)
    code(@user, D[7], 3 * HOUR, hackatime: "other-hackatime")
    scan
    assert_empty rows

    code(@user, D[8], 2 * HOUR, hackatime: "other-hackatime")
    scan
    assert_equal [ other.id ], rows.pluck(:subject_id)
  end

  test "archived projects and projects without a linked Hackatime project are skipped" do
    code(@user, D[7], 6 * HOUR)
    @project.update!(status: "archived", active: false)
    make_project(@user, name: "No link", hackatime: nil)
    result = scan
    assert_equal 0, result.scanned
    assert_empty rows
  end

  test "a person without a Slack id, not onboarded, or opted out gets nothing and the scan does not fail" do
    code(@user, D[7], 6 * HOUR)
    @user.update_columns(slack_id: nil)
    assert_equal 0, scan.queued

    @user.update_columns(slack_id: "UABC123", onboarded_at: nil)
    assert_equal 0, scan.queued

    @user.update_columns(onboarded_at: Time.utc(2026, 11, 1))
    Notifications::Preferences.update!(@user, "ship_reminder" => "0")
    assert_equal 0, scan.queued
    assert_empty rows

    Notifications::Preferences.update!(@user, "ship_reminder" => "1")
    assert_equal 1, scan.queued
  end

  test "opting out of the first reminder still allows the MVP nudge" do
    Notifications::Preferences.update!(@user, "ship_reminder" => "0")
    code(@user, D[7], 5 * HOUR)
    scan
    assert_empty rows
    code(@user, D[8], 5 * HOUR)
    scan
    assert_equal [ "ship_mvp" ], rows.pluck(:kind)
  end

  test "one failing project does not stop the scan" do
    make_project(@user, name: "Second", hackatime: "second-hackatime")
    code(@user, D[7], 6 * HOUR)
    calls = 0
    original = Ships::Window.method(:call)
    Ships::Window.define_singleton_method(:call) do |project|
      calls += 1
      raise "boom" if calls == 1

      original.call(project)
    end
    logs = capture_logs { scan }
    assert_includes logs, "notifications.ship_reminders error=RuntimeError"
    assert_equal 2, calls
  ensure
    Ships::Window.define_singleton_method(:call, original)
  end

  test "the rake task runs the scan" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("notifications:ship_reminders")
    code(@user, D[7], 5 * HOUR)
    Rake::Task["notifications:ship_reminders"].reenable
    out, = capture_io { Rake::Task["notifications:ship_reminders"].invoke }
    assert_match(/notifications:ship_reminders scanned=\d+ queued=\d+/, out)
    assert_equal 1, rows.count
  end
end
