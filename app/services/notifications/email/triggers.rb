module Notifications
  module Email
    # The seam between the Slack side of the outbox and email: what makes an email row get queued. Keyed on notification
    # kinds (Email::KINDS) so a new emailed kind is one line here, not a new code path.
    #
    #   ship_approved / ship_rejected  from Notifications::Triggers, in the same handler that queues the Slack DM for a
    #                                  decision (`ship_decision`). Email is additional: a person without a Slack id still
    #                                  gets their ship decision by email, and one switched off on one channel still gets
    #                                  it on the other.
    #   returning_nudge ("welcome back") whenever a Slack `returning_nudge` row is created for someone
    #                                  (`slack_row_created`, called from Notification's after_create_commit); the
    #                                  returning-user feature needs no email code of its own. The kind joins Email::KINDS the
    #                                  moment it exists in Notification::KINDS.
    #
    # Everything returns before doing any work while the Flipper flag `email` is off, so a flagged-off app creates no
    # email rows and runs no extra query. Like the Slack triggers, a failure is logged by class name and swallowed: it can
    # never break a teen's request or a staff member's approval. One email per event: the idempotency key carries the
    # channel ("email:" + the Slack row's key, or "email:ship_decision:<ship id>").
    module Triggers
      module_function

      # The ship decision email, queued next to the Slack DM. `kind` is "ship_approved" or "ship_rejected".
      def ship_decision(ship, kind)
        return nil unless Email.enabled? && Email::KINDS.include?(kind)

        guard(kind) do
          Outbox.enqueue(user: ship.user, kind: kind, subject_id: ship.id, key: "email:ship_decision:#{ship.id}", channel: Preferences::EMAIL)
        end
      end

      # The "your order shipped" email, queued next to the Slack DM. One per order (the key carries the channel).
      def order_shipped(order)
        return nil unless Email.enabled? && Email::KINDS.include?("order_shipped")

        guard("order_shipped") do
          Outbox.enqueue(user: order.user, kind: "order_shipped", subject_id: order.id, key: "email:order:#{order.id}:order_shipped", channel: Preferences::EMAIL)
        end
      end

      # A Slack outbox row was created. If its kind is one that also goes by email, queue the email.
      def slack_row_created(notification)
        return nil unless notification.channel == Preferences::SLACK && Email::FOLLOWS_SLACK_ROW.include?(notification.kind)
        return nil unless Email.enabled? && Email::KINDS.include?(notification.kind)

        guard(notification.kind) do
          Outbox.enqueue(user: notification.user, kind: notification.kind, subject_id: notification.subject_id,
                         key: "email:#{notification.idempotency_key}", now: notification.scheduled_for, channel: Preferences::EMAIL)
        end
      end

      def guard(kind)
        ActiveRecord::Base.transaction(requires_new: true) { yield }
      rescue StandardError => e
        Rails.logger.warn("notifications.email.trigger error=#{e.class.name} kind=#{kind}")
        nil
      end
      private_class_method :guard
    end
  end
end
