require "test_helper"
require "rake"
require_relative "../../support/notifications_helper"
require_relative "../../support/ships_test_support"

# The returning-user nudge (feature flag `returning`): one Slack DM per idle period, through the normal outbox and
# dispatcher. Fake adapter only: nothing real is sent.
class Notifications::ReturningNudgesTest < ActiveSupport::TestCase
  include NotificationsHelper
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }
  # The 1st is the last qualifying day; by noon on the 9th the 2nd to the 8th (seven days) are settled.
  IDLE_NOW = Time.utc(2026, 11, 9, 12)
  APP = "https://battletown.example"

  setup do
    @user = create_user(created_at: Time.utc(2026, 11, 1, 9))
    @user.update_columns(signed_up_on: D[1])
    code(@user, D[1], 900)
  end

  def scan(now: IDLE_NOW) = Notifications::ReturningNudges.scan(now: now)

  def rows(user = @user) = Notification.where(user_id: user.id, kind: "returning_nudge").order(:id)

  def dispatch(adapter, now:)
    with_env("NOTIFICATIONS_ENABLED" => "true", "APP_URL" => APP) { Notifications::Dispatcher.run(now: now, adapter: adapter) }
  end

  # --- the flag ---

  test "with the flag off the scan reads nothing and queues nothing" do
    without_feature(:returning) do
      result = scan
      assert_equal [ 0, 0 ], [ result.scanned, result.queued ]
      assert_equal 0, Notification.where(kind: "returning_nudge").count
      assert_equal 0, DailyResult.where(user_id: @user.id).count
    end
  end

  test "a nudge queued before the flag was switched off is cancelled, not sent" do
    row = with_feature(:returning) { scan; rows.first }
    adapter = FakeAdapter.new
    without_feature(:returning) { dispatch(adapter, now: IDLE_NOW + 1.minute) }
    assert_empty adapter.calls
    assert_equal [ "cancelled", "subject_gone" ], [ row.reload.status, row.last_error_code ]
  end

  # --- who is nudged, and when ---

  test "seven idle days queue exactly one nudge, however often the scan runs" do
    with_feature(:returning) do
      assert_equal 1, scan.queued
      assert_equal 0, scan.queued
      assert_equal 0, scan(now: IDLE_NOW + 1.day).queued
      row = rows.sole
      assert_equal "returning_nudge:#{@user.id}:2026-11-01", row.idempotency_key
      assert_equal Notifications::ReturningNudges.subject_for(D[1]), row.subject_id
      assert_equal [ "pending", "slack_dm" ], [ row.status, row.channel ]
    end
  end

  test "six idle days are not enough" do
    with_feature(:returning) do
      assert_equal 0, scan(now: Time.utc(2026, 11, 8, 12)).queued
      assert_equal 0, rows.count
    end
  end

  test "someone idle for longer than the cap is not nudged" do
    with_feature(:returning) do
      assert_equal 0, scan(now: Time.utc(2026, 12, 20, 12)).queued
      assert_equal 0, rows.count
    end
  end

  test "someone who is already back today is not nudged" do
    with_feature(:returning) do
      code(@user, D[9], 900)
      assert_equal 0, scan.queued
    end
  end

  test "a person with no qualifying day ever is never nudged, however long since sign-up" do
    with_feature(:returning) do
      quiet = create_user(created_at: Time.utc(2026, 10, 1, 9))
      quiet.update_columns(signed_up_on: Date.new(2026, 10, 1))
      code(quiet, D[1], 600)
      scan
      assert_equal 0, rows(quiet).count
    end
  end

  test "someone who has not finished onboarding, has no Slack id or switched the kind off gets nothing" do
    with_feature(:returning) do
      unfinished = create_user(created_at: Time.utc(2026, 11, 1, 9), onboarded_at: nil)
      no_slack = create_user(created_at: Time.utc(2026, 11, 1, 9), slack_id: nil)
      opted_out = create_user(created_at: Time.utc(2026, 11, 1, 9))
      NotificationPreference.create!(user: opted_out, kind: "returning_nudge", enabled: false)
      [ unfinished, no_slack, opted_out ].each do |user|
        user.update_columns(signed_up_on: D[1])
        code(user, D[1], 900)
      end

      assert_equal 1, scan.queued
      assert_equal [ 1, 0, 0, 0 ], [ @user, unfinished, no_slack, opted_out ].map { |user| rows(user).count }
    end
  end

  test "an account that was deleted has nothing queued, and its queued nudge goes with it" do
    with_feature(:returning) do
      scan
      assert_equal 1, Notification.where(kind: "returning_nudge").count
      User.where(id: @user.id).delete_all
      assert_equal 0, Notification.where(kind: "returning_nudge").count
      assert_equal 0, scan.queued
    end
  end

  test "coming back and going quiet again is a new idle period with its own nudge" do
    with_feature(:returning) do
      scan
      code(@user, D[12], 900)
      assert_equal 0, scan(now: Time.utc(2026, 11, 13, 12)).queued
      assert_equal 1, scan(now: Time.utc(2026, 11, 20, 12)).queued
      assert_equal [ "returning_nudge:#{@user.id}:2026-11-01", "returning_nudge:#{@user.id}:2026-11-12" ], rows.pluck(:idempotency_key)
    end
  end

  test "someone who has used up their windows is not nudged again" do
    with_feature(:returning) do
      [ D[2], D[3], D[4] ].each { |day| WelcomeBackWindow.create!(user: @user, starts_on: day, ends_on: day + 2, idle_days: 7) }
      assert_equal 0, scan.queued
    end
  end

  # --- delivery ---

  test "the dispatcher sends the nudge with the dashboard link, in plain friendly words" do
    with_feature(:returning) do
      scan
      adapter = FakeAdapter.new
      summary = dispatch(adapter, now: IDLE_NOW + 1.minute)
      assert_equal 1, summary.sent
      text = adapter.calls.sole.fetch(:text)
      assert_equal @user.slack_id, adapter.calls.sole.fetch(:slack_id)
      assert_includes text, "#{APP}/dashboard"
      assert_includes text, "3 days"
      assert_includes text, "Hack Club"
      assert_no_match(/hackclub|HackClub|hack club|gone|days ago|broke/, text)
    end
  end

  test "quiet hours hold the nudge until the person's morning" do
    with_feature(:returning) do
      late = Time.utc(2026, 11, 9, 23, 0)
      scan(now: late)
      adapter = FakeAdapter.new
      assert_equal 1, dispatch(adapter, now: late + 1.minute).deferred
      assert_empty adapter.calls
      assert_equal 1, dispatch(adapter, now: Time.utc(2026, 11, 10, 7, 1)).sent
    end
  end

  test "switching the kind off after it was queued cancels it" do
    with_feature(:returning) do
      scan
      NotificationPreference.create!(user: @user, kind: "returning_nudge", enabled: false)
      adapter = FakeAdapter.new
      summary = dispatch(adapter, now: IDLE_NOW + 1.minute)
      assert_equal 1, summary.cancelled
      assert_empty adapter.calls
    end
  end

  test "the kill switch keeps everything in the outbox" do
    with_feature(:returning) do
      scan
      adapter = FakeAdapter.new
      with_env("NOTIFICATIONS_ENABLED" => nil) { Notifications::Dispatcher.run(now: IDLE_NOW, adapter: adapter) }
      assert_empty adapter.calls
      assert_equal "pending", rows.sole.status
    end
  end

  test "coming back before it is sent cancels the nudge" do
    with_feature(:returning) do
      scan
      code(@user, D[9], 900)
      adapter = FakeAdapter.new
      travel_to(IDLE_NOW + 1.minute) { dispatch(adapter, now: Time.current) }
      assert_empty adapter.calls
      assert_equal "subject_gone", rows.sole.last_error_code
    end
  end

  # --- the task ---

  test "the rake task runs the scan" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("notifications:returning_nudges")
    Rake::Task["notifications:returning_nudges"].reenable
    out, = capture_io { Rake::Task["notifications:returning_nudges"].invoke }
    assert_match(/notifications:returning_nudges scanned=0 queued=0/, out)
  end
end
