require "test_helper"
require_relative "../../support/notifications_helper"
require_relative "../../support/ships_test_support"
require_relative "../../support/coins_helper"

# The real subscribers (config/initializers/notification_triggers.rb) fed by the real events fired from the projects
# and ships code. Nothing is sent: these tests only look at the outbox.
class Notifications::TriggersTest < ActiveSupport::TestCase
  include NotificationsHelper
  include ShipsTestSupport
  include CoinsHelper

  D = ->(day) { Date.new(2026, 11, day) }

  setup do
    @user = create_user
    @project = make_project(@user)
    @reviewer = users(:onboarded)
  end

  def rows(kind = nil)
    scope = Notification.where(user_id: @user.id).where.not(kind: "daily_reminder")
    kind ? scope.where(kind: kind) : scope
  end

  def suggest(project = @project, name: "space-farm-2")
    suggestion = project.link_suggestions.create!(hackatime_project: name)
    ActiveSupport::Notifications.instrument("project_link_suggested.battletown", suggestion_id: suggestion.id)
    suggestion
  end

  def submitted_ship(days: [ 7, 8, 9 ])
    days.each { |day| code(@user, D[day], HOUR) }
    submit_ship(@project)
  end

  def approve(ship)
    Ships::Approve.call(ship: ship, reviewer: @reviewer, approved_seconds: ship.coded_seconds, now: Time.utc(2026, 11, 10, 12))
  end

  # --- link question ---

  test "a new link suggestion queues exactly one link_question, even when the event repeats" do
    suggestion = suggest
    assert_equal 1, rows("link_question").count
    row = rows("link_question").sole
    assert_equal suggestion.id, row.subject_id
    assert_equal "link_question:#{suggestion.id}", row.idempotency_key
    assert row.pending?

    3.times { ActiveSupport::Notifications.instrument("project_link_suggested.battletown", suggestion_id: suggestion.id) }
    assert_equal 1, rows("link_question").count
  end

  test "each suggestion gets its own question and an answered one gets none" do
    suggest(name: "one")
    suggest(name: "two")
    assert_equal 2, rows("link_question").count

    answered = @project.link_suggestions.create!(hackatime_project: "three", state: "declined")
    ActiveSupport::Notifications.instrument("project_link_suggested.battletown", suggestion_id: answered.id)
    assert_equal 2, rows("link_question").count
  end

  # --- ship decisions ---

  test "approving a ship queues one ship_approved, even when the event repeats" do
    ship = submitted_ship
    assert_empty rows, "submitting alone sends nothing"
    approve(ship)

    assert_equal 1, rows.count
    row = rows("ship_approved").sole
    assert_equal [ ship.id, "ship_decision:#{ship.id}" ], [ row.subject_id, row.idempotency_key ]

    2.times { ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id) }
    assert_equal 1, rows.count
  end

  test "rejecting a ship queues one ship_rejected and never a second decision for the same ship" do
    ship = submitted_ship
    Ships::Reject.call(ship: ship, reviewer: @reviewer, reason: "The demo link does not open.")

    assert_equal [ "ship_rejected" ], rows.pluck(:kind)
    2.times { ActiveSupport::Notifications.instrument("ship_rejected.battletown", ship_id: ship.id) }
    ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id)
    assert_equal 1, rows.count
  end

  test "an event for a ship that is not in that state, or no longer exists, queues nothing" do
    ship = submitted_ship
    ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id)
    ActiveSupport::Notifications.instrument("ship_rejected.battletown", ship_id: ship.id)
    ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: 0)
    assert_empty rows
  end

  test "submitting a ship cancels the pending ship reminders of its project and queues nothing" do
    code(@user, D[7], 5 * HOUR)
    Notifications::ShipReminders.scan(now: Time.utc(2026, 11, 10, 12))
    reminder = rows("ship_reminder").sole
    assert reminder.pending?

    submit_ship(@project)
    assert reminder.reload.cancelled?
    assert_equal 1, rows.count
  end

  # --- who gets nothing ---

  test "a user without a Slack id gets nothing and nothing raises" do
    user = create_user(slack_id: nil)
    project = make_project(user, hackatime: "no-slack")
    assert_nothing_raised { suggest(project, name: "x") }
    assert_equal 0, Notification.where(user_id: user.id).where.not(kind: "daily_reminder").count
  end

  test "a user who switched the kind off gets no row at queue time" do
    Notifications::Preferences.update!(@user, "link_question" => "0", "ship_approved" => "0")
    suggest
    approve(submitted_ship)
    assert_empty rows
  end

  test "switching one kind off leaves the others queueing" do
    Notifications::Preferences.update!(@user, "ship_approved" => "0")
    suggest
    assert_equal [ "link_question" ], rows.pluck(:kind)
  end

  # --- errors stay inside the handler ---

  test "a failing handler logs only the error class and never raises into the caller" do
    suggestion = @project.link_suggestions.create!(hackatime_project: "boom")
    original = Notifications::Outbox.method(:enqueue)
    Notifications::Outbox.define_singleton_method(:enqueue) { |**| raise ArgumentError, "secret detail U123ABC for someone@example.com" }
    logs = capture_logs do
      assert_nothing_raised { ActiveSupport::Notifications.instrument("project_link_suggested.battletown", suggestion_id: suggestion.id) }
    end
    assert_includes logs, "notifications.trigger error=ArgumentError"
    assert_no_match(/secret detail|U123ABC|someone@example\.com/, logs)
  ensure
    Notifications::Outbox.define_singleton_method(:enqueue, original)
  end

  test "a database error inside a handler does not poison the surrounding transaction" do
    ship = submitted_ship
    original = Notifications::Outbox.method(:enqueue)
    Notifications::Outbox.define_singleton_method(:enqueue) { |**| Notification.connection.execute("SELECT * FROM table_that_is_not_there") }
    Notification.transaction do
      assert_nothing_raised { ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id) }
      assert_equal 1, User.where(id: @user.id).count, "the outer transaction is still usable"
    end
  ensure
    Notifications::Outbox.define_singleton_method(:enqueue, original)
  end

  test "handlers are subscribed exactly once" do
    suggestion = @project.link_suggestions.create!(hackatime_project: "once")
    calls = 0
    original = Notifications::Triggers.method(:link_suggested)
    Notifications::Triggers.define_singleton_method(:link_suggested) { |payload| calls += 1; original.call(payload) }
    ActiveSupport::Notifications.instrument("project_link_suggested.battletown", suggestion_id: suggestion.id)
    assert_equal 1, calls
  ensure
    Notifications::Triggers.define_singleton_method(:link_suggested, original)
  end
end
