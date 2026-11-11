module Notifications
  # Slack delivery sits behind an adapter so nothing in the app talks to Slack directly and tests never touch the
  # network. `Notifications::Slack.adapter` picks the implementation:
  #
  # - WebApiAdapter only when SLACK_BOT_TOKEN is present and Rails.env is not test (a real send);
  # - LogAdapter in development (logs only the event name, never the recipient or text);
  # - NullAdapter otherwise (does nothing and reports ok).
  module Slack
    def self.adapter
      if ENV["SLACK_BOT_TOKEN"].present? && !Rails.env.test?
        WebApiAdapter.new
      elsif Rails.env.development?
        LogAdapter.new
      else
        NullAdapter.new
      end
    end
  end
end
