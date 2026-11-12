module Notifications
  module Email
    # Interface of an email transport, the counterpart of Slack::Adapter. Implementations return a Result and must not
    # raise for delivery problems. `delivers?` says whether this really reaches people: the dispatcher refuses to run
    # in production with an adapter that does not, and anywhere else records what it handled as skipped, so the
    # absence of an SMTP server can never mark a row sent.
    class Adapter
      def deliver(user:, kind:, values:)
        raise NotImplementedError, "#{self.class} must implement deliver"
      end

      def delivers? = false
    end
  end
end
