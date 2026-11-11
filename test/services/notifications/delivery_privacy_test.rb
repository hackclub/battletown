require "test_helper"
require_relative "../../support/notifications_helper"

# End to end through the real WebApiAdapter with Net::HTTP stubbed: nothing sensitive may reach the database or logs.
class Notifications::DeliveryPrivacyTest < ActiveSupport::TestCase
  include NotificationsHelper

  DUE = Time.utc(2026, 11, 11, 18, 30)

  setup do
    @user = create_user
    Notifications::Scheduler.schedule_next(@user, now: DUE - 6.hours)
  end

  def run_with(response: nil, error: nil)
    config = Notifications::Config.current
    logs = capture_logs do
      stub_http(response: response, error: error) do
        with_env("NOTIFICATIONS_ENABLED" => "true") do
          adapter = Notifications::Slack::WebApiAdapter.new(token: TOKEN)
          Notifications::Dispatcher.run(now: DUE + 1.minute, adapter: adapter, config: config)
        end
      end
    end
    [ logs, config ]
  end

  def stored_text
    Notification.all.map { |row| row.attributes.values.join(" ") }.join(" ")
  end

  test "success, Slack errors and network errors never leak the token, Slack id or text" do
    [ { response: json_response({ ok: true }) },
      { response: json_response({ ok: false, error: "invalid_auth" }) },
      { response: json_response({ ok: false, error: "user_not_found" }) },
      { response: json_response("not json #{TOKEN}", code: "502") },
      { error: Net::ReadTimeout.new("timed out talking with #{TOKEN} about #{@user.slack_id}") } ].each do |scenario|
      Notification.delete_all
      Notifications::Scheduler.schedule_next(@user, now: DUE - 6.hours)
      logs, config = run_with(**scenario)

      [ logs, stored_text ].each do |haystack|
        assert_not_includes haystack, TOKEN
        assert_not_includes haystack, @user.slack_id
        assert_not_includes haystack, config.template("daily_reminder")
      end
    end
  end

  test "the real adapter sends the template text to the user's Slack id" do
    _logs, config = run_with(response: json_response({ ok: true }))
    assert_equal "sent", Notification.where(user: @user).order(:id).first.status
    body = nil
    stub_http(response: json_response({ ok: true })) do |seen|
      Notifications::Slack::WebApiAdapter.new(token: TOKEN).deliver_dm(slack_id: @user.slack_id, text: config.template("daily_reminder"))
      body = JSON.parse(seen[:http].requests.sole.body)
    end
    assert_equal @user.slack_id, body["channel"]
    assert_equal config.template("daily_reminder"), body["text"]
  end
end
