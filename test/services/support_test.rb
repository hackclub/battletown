require "test_helper"

# Where to ask for help (the order page, the not-eligible note): never invented, and never a malformed value.
class SupportTest < ActiveSupport::TestCase
  def with_support(email: nil, channel: nil)
    config = Rails.configuration.x.support
    before = [ config.email, config.slack_channel ]
    config.email = email
    config.slack_channel = channel
    yield
  ensure
    config.email, config.slack_channel = before
  end

  test "with nothing configured there is no email and the neutral channel wording" do
    with_support do
      assert_nil Support.email
      assert_nil Support.channel_name
      assert_equal "the Battletown channel in the Hack Club Slack", Support.channel_text
      assert_equal "the Battletown channel in the Hack Club Slack", Support.where_to_ask
    end
  end

  test "a configured channel and email are both shown" do
    with_support(email: "help@example.org", channel: "#Battletown") do
      assert_equal "help@example.org", Support.email
      assert_equal "battletown", Support.channel_name
      assert_equal "the #battletown channel in the Hack Club Slack", Support.channel_text
      assert_equal "the #battletown channel in the Hack Club Slack, or email help@example.org", Support.where_to_ask
    end
  end

  test "an email alone keeps the neutral channel wording" do
    with_support(email: "help@example.org") do
      assert_equal "the Battletown channel in the Hack Club Slack, or email help@example.org", Support.where_to_ask
    end
  end

  test "malformed values are ignored rather than shown" do
    with_support(email: "not an email <x>", channel: "two words!") do
      assert_nil Support.email
      assert_nil Support.channel_name
      assert_equal Support::FALLBACK_CHANNEL, Support.where_to_ask
    end
  end
end
