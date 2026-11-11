module Notifications
  module Slack
    # Does nothing and reports success. The default outside development and when no bot token is configured.
    class NullAdapter < Adapter
      def deliver_dm(slack_id:, text:)
        Result.success
      end
    end
  end
end
