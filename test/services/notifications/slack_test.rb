require "test_helper"
require_relative "../../support/notifications_helper"

class Notifications::SlackTest < ActiveSupport::TestCase
  include NotificationsHelper

  test "the test environment never gets the real adapter, even with a token" do
    with_env("SLACK_BOT_TOKEN" => TOKEN) do
      assert_instance_of Notifications::Slack::NullAdapter, Notifications::Slack.adapter
    end
  end

  test "WebApi only with a token outside test; log adapter in development; null otherwise" do
    with_env("SLACK_BOT_TOKEN" => TOKEN) do
      with_rails_env("production") { assert_instance_of Notifications::Slack::WebApiAdapter, Notifications::Slack.adapter }
      with_rails_env("development") { assert_instance_of Notifications::Slack::WebApiAdapter, Notifications::Slack.adapter }
    end
    with_env("SLACK_BOT_TOKEN" => nil) do
      with_rails_env("production") { assert_instance_of Notifications::Slack::NullAdapter, Notifications::Slack.adapter }
      with_rails_env("development") { assert_instance_of Notifications::Slack::LogAdapter, Notifications::Slack.adapter }
    end
    with_env("SLACK_BOT_TOKEN" => "") do
      with_rails_env("production") { assert_instance_of Notifications::Slack::NullAdapter, Notifications::Slack.adapter }
    end
  end

  test "the null adapter does nothing and reports ok; it does not claim to deliver" do
    adapter = Notifications::Slack::NullAdapter.new
    assert adapter.deliver_dm(slack_id: "U1", text: "hi").ok?
    assert_not adapter.delivers?
  end

  test "the log adapter logs only the event name" do
    logs = capture_logs { assert Notifications::Slack::LogAdapter.new.deliver_dm(slack_id: "U0PRIVATE1", text: "private words").ok? }
    assert_includes logs, "notifications.slack.deliver_dm"
    assert_not_includes logs, "U0PRIVATE1"
    assert_not_includes logs, "private words"
  end

  test "the base adapter is an interface" do
    assert_raises(NotImplementedError) { Notifications::Slack::Adapter.new.deliver_dm(slack_id: "U1", text: "x") }
  end
end
