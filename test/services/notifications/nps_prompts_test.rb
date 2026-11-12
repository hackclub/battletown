require "test_helper"
require "rake"
require_relative "../../support/notifications_helper"
require_relative "../../support/ships_test_support"

# The survey DM: the scan that queues it (flag nps), then the real dispatcher with a fake adapter (never a real Slack call).
class Notifications::NpsPromptsTest < ActiveSupport::TestCase
  include NotificationsHelper
  include ShipsTestSupport

  NOW = Time.utc(2026, 11, 12, 15) # mid-afternoon in UTC, outside quiet hours
  TODAY = Date.new(2026, 11, 12)
  APP = "https://battletown.example"

  setup do
    @user = create_user
    code(@user, TODAY - 1, 20.minutes.to_i)
  end

  def scan(now: NOW) = Notifications::NpsPrompts.scan(now: now)

  def rows = Notification.where(kind: "nps_prompt")

  def dispatch(adapter, now: NOW + 1.minute)
    with_env("NOTIFICATIONS_ENABLED" => "true", "APP_URL" => APP) { Notifications::Dispatcher.run(now: now, adapter: adapter) }
  end

  # --- the flag ---

  test "with the flag off the scan reads nothing, queues nothing and reports zero" do
    assert_equal [ 0, 0 ], scan.to_h.values
    assert_equal 0, rows.count
  end

  test "with the flag on an active person gets exactly one pending row for their window" do
    with_feature(:nps) do
      assert_equal [ 1, 1 ], scan.to_h.values
      row = rows.sole
      assert_equal [ @user.id, "pending", "slack_dm", 20261112 ], [ row.user_id, row.status, row.channel, row.subject_id ]
      assert_equal "nps_prompt:#{@user.id}:2026-11-12", row.idempotency_key
    end
  end

  test "scanning again, or from two places, never queues a second one" do
    with_feature(:nps) do
      scan
      assert_equal 0, scan.queued
      assert_equal 0, scan(now: NOW + 3.hours).queued
      assert_equal 1, rows.count
    end
  end

  test "two days later they are asked again, not before" do
    with_feature(:nps) do
      scan
      assert_equal 0, scan(now: NOW + 1.day).queued
      code(@user, TODAY, 1200)
      assert_equal 1, scan(now: NOW + 2.days).queued
      assert_equal 2, rows.count
    end
  end

  test "people who are not active, not onboarded or without a Slack id get nothing" do
    idle = create_user
    code(idle, TODAY - 10, 3600)
    fresh = create_user(onboarded_at: nil)
    code(fresh, TODAY - 1, 3600)
    no_slack = create_user(slack_id: nil)
    code(no_slack, TODAY - 1, 3600)
    with_feature(:nps) do
      scan
      assert_equal [ @user.id ], rows.pluck(:user_id)
    end
  end

  test "someone who switched the survey off is not queued" do
    NotificationPreference.create!(user: @user, kind: "nps_prompt", enabled: false)
    with_feature(:nps) do
      assert_equal 0, scan.queued
      assert_equal 0, rows.count
    end
  end

  test "someone who answered recently is not queued" do
    NpsResponse.create!(user: @user, score: 9, answered_at: NOW - 3.days, prompt_window_date: TODAY - 3)
    with_feature(:nps) { assert_equal 0, scan.queued }
  end

  test "an error on one person does not stop the others" do
    other = create_user
    code(other, TODAY - 1, 1200)
    with_feature(:nps) do
      calls = 0
      original = Nps::Eligibility.method(:check)
      Nps::Eligibility.define_singleton_method(:check) do |user, **options|
        calls += 1
        raise "boom" if calls == 1

        original.call(user, **options)
      end
      begin
        assert_equal [ 2, 1 ], scan.to_h.values
      ensure
        Nps::Eligibility.define_singleton_method(:check, original)
      end
    end
  end

  test "the rake task queues, reports and does nothing while the flag is off" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("notifications:nps_prompts")
    run = lambda do
      Rake::Task["notifications:nps_prompts"].reenable
      capture_io { Rake::Task["notifications:nps_prompts"].invoke }.first
    end
    assert_match(/queued=0/, run.call)
    assert_equal 0, rows.count
    with_feature(:nps) do
      travel_to(NOW) { assert_match(/queued=1/, run.call) }
      assert_equal 1, rows.count
    end
  end

  # --- delivery ---

  def queued_row
    with_feature(:nps) { scan }
    rows.sole
  end

  test "the dispatcher sends one DM with a working survey link and nothing personal" do
    row = queued_row
    adapter = FakeAdapter.new
    with_feature(:nps) { dispatch(adapter) }
    assert_equal "sent", row.reload.status
    call = adapter.calls.sole
    assert_equal @user.slack_id, call[:slack_id]
    assert_includes call[:text], "recommend Battletown"
    link = call[:text][%r{#{Regexp.escape(APP)}/feedback/(\S+)}, 1]
    claims = Nps::Token.parse(link)
    assert_equal [ @user.id, TODAY ], [ claims.user_id, claims.window_date ]
    assert_no_match(/hackclub|HackClub|hack club/, call[:text])
    assert_no_match(/#{Regexp.escape(@user.display_name.to_s)}|#{Regexp.escape(@user.email.to_s)}/, call[:text]) if @user.display_name.present? && @user.email.present?
  end

  test "the kill switch keeps it unsent" do
    row = queued_row
    adapter = FakeAdapter.new
    with_feature(:nps) { with_env("NOTIFICATIONS_ENABLED" => nil) { Notifications::Dispatcher.run(now: NOW + 1.minute, adapter: adapter) } }
    assert_empty adapter.calls
    assert_equal "pending", row.reload.status
  end

  test "quiet hours move it to the end of the person's night, in their own time zone" do
    @user.update!(time_zone: "Pacific Time (US & Canada)") # 15:00 UTC is 07:00 in Los Angeles: ok
    la = create_user(time_zone: "Pacific Time (US & Canada)")
    code(la, TODAY - 2, 1200)
    now = Time.utc(2026, 11, 12, 9) # 01:00 in Los Angeles: quiet
    with_feature(:nps) { scan(now: now) }
    adapter = FakeAdapter.new
    with_feature(:nps) { dispatch(adapter, now: now + 1.minute) }
    assert_empty adapter.calls.select { |call| call[:slack_id] == la.slack_id }
    row = rows.find_by!(user_id: la.id)
    assert_equal "pending", row.status
    assert_operator row.due_at, :>, now + 1.minute
    assert_equal 7, row.due_at.in_time_zone("Pacific Time (US & Canada)").hour
  end

  test "an opt-out after queueing cancels it" do
    row = queued_row
    NotificationPreference.create!(user: @user, kind: "nps_prompt", enabled: false)
    adapter = FakeAdapter.new
    with_feature(:nps) { dispatch(adapter) }
    assert_empty adapter.calls
    assert_equal [ "cancelled", "opted_out" ], [ row.reload.status, row.last_error_code ]
  end

  test "losing the Slack id after queueing sends nothing" do
    row = queued_row
    @user.update_columns(slack_id: nil)
    adapter = FakeAdapter.new
    with_feature(:nps) { dispatch(adapter) }
    assert_empty adapter.calls
    assert_equal "cancelled", row.reload.status
  end

  test "switching the flag off after queueing sends nothing and cancels the row" do
    row = queued_row
    adapter = FakeAdapter.new
    without_feature(:nps) { dispatch(adapter) }
    assert_empty adapter.calls
    assert_equal [ "cancelled", "subject_gone" ], [ row.reload.status, row.last_error_code ]
  end

  test "answering before it is sent cancels it" do
    row = queued_row
    NpsResponse.create!(user: @user, score: 6, answered_at: NOW, prompt_window_date: TODAY)
    adapter = FakeAdapter.new
    with_feature(:nps) { dispatch(adapter) }
    assert_empty adapter.calls
    assert_equal "cancelled", row.reload.status
  end

  test "a retry sends a fresh link, and the log never carries the token, the link or the address" do
    queued_row
    adapter = FakeAdapter.new
    logs = capture_logs { with_feature(:nps) { dispatch(adapter) } }
    token = adapter.calls.sole[:text][%r{/feedback/(\S+)}, 1]
    assert_not_includes logs, token
    assert_not_includes logs, "/feedback/"
    assert_not_includes logs, @user.slack_id
  end

  test "the template is short, friendly and has a link" do
    template = Notifications::Config.current.template("nps_prompt")
    assert_operator template.length, :<=, 280
    assert_includes template, "{link}"
    assert_equal "Quick survey", Notifications::Config.current.label("nps_prompt")["title"]
  end
end
