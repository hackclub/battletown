module Notifications
  module Email
    # The global "no email at all" switch (`users.email_opted_out_at`). Turned on by the unsubscribe link or the settings
    # page, turned off only by the person on the settings page.
    module Subscription
      module_function

      # Idempotent: an already-unsubscribed person keeps their original timestamp. Whatever email is still queued for
      # them is cancelled (the dispatcher would drop it anyway, this just keeps the outbox honest).
      def unsubscribe!(user)
        touch_columns(user, email_opted_out_at: Time.current) unless user.email_opted_out?
        Notification.where(user_id: user.id, channel: CHANNEL, status: "pending")
                    .update_all(status: "cancelled", last_error_code: "opted_out", updated_at: Time.current)
        true
      end

      # Rotating the nonce revokes every unsubscribe link already sent: a link in an old email stops working, and new
      # emails carry a new one.
      def resubscribe!(user)
        return false unless user.email_opted_out?

        touch_columns(user, email_opted_out_at: nil, email_unsubscribe_nonce: SecureRandom.uuid)
        true
      end

      # No validations: an address that no longer passes them must never stop someone from opting out.
      def touch_columns(user, **columns) = user.update_columns(columns.merge(updated_at: Time.current))
      private_class_method :touch_columns
    end
  end
end
