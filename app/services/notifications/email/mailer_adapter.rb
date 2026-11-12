require "net/smtp"
require "openssl"

module Notifications
  module Email
    # Builds the message with NotificationMailer and hands it to whatever delivery method Action Mailer is configured
    # with: :smtp in production only when the environment describes a complete transport (config/email_transport.rb),
    # :test in the test suite (mail collects in ActionMailer::Base.deliveries), and :test with deliveries switched off
    # in development and in production without SMTP (nothing is kept or sent).
    #
    # Logs one line, "notifications.email queued kind=<kind>": never the address, the subject or the body (and Action
    # Mailer's own log is silenced, config/initializers/mailer_privacy.rb). Errors are logged by class only.
    class MailerAdapter < Adapter
      # An SMTP server that is down, slow or busy: try again later.
      RETRYABLE = [ Net::SMTPServerBusy, Net::SMTPUnknownError, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, IOError, SocketError,
                    SystemCallError, OpenSSL::SSL::SSLError ].freeze

      def deliver(user:, kind:, values:)
        Rails.logger.info("notifications.email queued kind=#{kind}")
        NotificationMailer.with(user: user, values: values).public_send(kind).deliver_now
        Result.success
      rescue Net::SMTPAuthenticationError
        # Our credentials, not this recipient: stop the whole run.
        failure("smtp_auth", retryable: false, systemic: true)
      rescue Net::SMTPFatalError, Net::SMTPSyntaxError
        failure("smtp_rejected", retryable: false)
      rescue *RETRYABLE
        failure("smtp_unavailable", retryable: true)
      end

      # Only a real SMTP transport delivers.
      def delivers?
        ActionMailer::Base.delivery_method == :smtp && ActionMailer::Base.perform_deliveries
      end

      private

      def failure(code, retryable:, systemic: false)
        Rails.logger.warn("notifications.email failed code=#{code}")
        Result.failure(code, retryable: retryable, systemic: systemic)
      end
    end
  end
end
