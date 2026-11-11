module Notifications
  module Slack
    # Interface. Implementations return a Result and must not raise for delivery problems.
    class Adapter
      def deliver_dm(slack_id:, text:)
        raise NotImplementedError, "#{self.class} must implement deliver_dm"
      end

      # Whether this adapter really reaches people. The dispatcher refuses to run in production with an adapter that
      # does not, so a missing token cannot quietly mark reminders as sent.
      def delivers? = false
    end
  end
end
