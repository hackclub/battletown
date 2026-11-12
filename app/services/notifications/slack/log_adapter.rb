module Notifications
  module Slack
    # Development: proves the pipeline runs. Logs the event name only, never the Slack id or the text. It does not
    # deliver, so the dispatcher records its rows as skipped, never sent.
    class LogAdapter < Adapter
      def deliver_dm(slack_id:, text:)
        Rails.logger.info("notifications.slack.deliver_dm adapter=log")
        Result.success
      end
    end
  end
end
