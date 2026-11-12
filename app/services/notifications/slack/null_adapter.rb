module Notifications
  module Slack
    # Does nothing and reports success. The default outside development and when no bot token is configured. It does
    # not deliver, so the dispatcher records its rows as skipped, never sent.
    class NullAdapter < Adapter
      def deliver_dm(slack_id:, text:)
        Result.success
      end
    end
  end
end
