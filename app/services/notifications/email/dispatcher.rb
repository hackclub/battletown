module Notifications
  module Email
    # Sends the due email rows of the outbox, by the same rules as the Slack dispatcher it extends (kill switch
    # NOTIFICATIONS_ENABLED, claim and lease with FOR UPDATE SKIP LOCKED, quiet hours, lateness, backoff, a row is only
    # ever "sent" when a real transport said so), plus:
    #
    # - The Flipper flag `email`: with it off the run does nothing at all (no query, no mail), so rows left over from
    #   before the flag was switched off wait untouched.
    # - In production it refuses to run without a real SMTP transport (SMTP_ADDRESS and MAIL_FROM, config/email_transport.rb)
    #   and never marks anything sent; elsewhere the mail is built and dropped and the row is "skipped" (not_delivered).
    # - A row is cancelled (never sent, never "sent") when the person has no usable address ("no_address"), switched
    #   that kind or all email off ("opted_out"), or is over the weekly cap for nudges ("weekly_cap").
    # - The address is read from the user at send time only. It is never stored on the row and never logged.
    class Dispatcher < Notifications::Dispatcher
      def self.enabled? = super && Email.enabled?

      def self.channel = Preferences::EMAIL

      def self.run(now: Time.current, limit: 100, adapter: Email.adapter, config: Notifications::Config.current)
        new(now: now, limit: limit, adapter: adapter, config: config).run
      end

      private

      def recipient_problem(_row, user)
        return "schedule_changed" unless user.onboarded?

        "no_address" unless Email.valid_address?(user.email)
      end

      # Nudges are capped per person per week (config: email.max_per_week, email.capped_kinds). Counts what was really
      # sent or already leased to a send in the last 7 days.
      def veto(row, _user)
        email = Email::Config.current
        return nil unless email.capped?(row.kind)

        recent = Notification.where(user_id: row.user_id, channel: Email::CHANNEL, kind: email.capped_kinds)
                             .where(status: "sent", sent_at: (@now - 7.days)..).where.not(id: row.id).count
        "weekly_cap" if recent >= email.max_per_week
      end

      # The facts the template needs, or nil when the thing the email is about is gone (the row is then cancelled).
      def build_content(row, user) = Content.build(row, user)

      def deliver(row, user, values)
        @adapter.deliver(user: user, kind: row.kind, values: values)
      rescue StandardError => e
        # Never log e.message: an SMTP error can carry the recipient.
        Rails.logger.warn("notifications.dispatch adapter_error class=#{e.class.name}")
        Email::Result.failure("adapter_error", retryable: true)
      end
    end
  end
end
