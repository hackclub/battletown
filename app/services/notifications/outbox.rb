module Notifications
  # The one way an event notification gets into the outbox. Returns the Notification (new, or the existing one when
  # the same idempotency key was already queued), or nil when the person should get nothing: no Slack id, not
  # onboarded, or they switched this kind off. Never raises for those cases.
  #
  # `channel` is slack_dm (the default) or email. A Slack row needs a Slack id; an email row needs a usable address on the
  # person (never copied onto the row) and the kind switched on for email, which includes the "no email at all" switch.
  # The email flag is the caller's business (Email::Triggers).
  #
  # Idempotent on `key` (the unique idempotency_key index decides races), so a duplicate event, a repeated scan or
  # two workers can never queue a second message. No text and no address is stored: the dispatcher builds the text
  # and reads the Slack id when it sends. Quiet hours are applied by the dispatcher (it moves the send to the end of
  # the person's quiet window).
  module Outbox
    module_function

    def enqueue(user:, kind:, subject_id:, key:, now: Time.current, channel: Preferences::SLACK)
      return nil unless eligible?(user, kind, channel)

      Notification.find_by(idempotency_key: key) || create_or_find(user, kind, subject_id, key, now, channel)
    end

    def eligible?(user, kind, channel = Preferences::SLACK)
      return false unless user.present? && user.onboarded? && Preferences.enabled?(user, kind, channel: channel)

      channel == Preferences::EMAIL ? Email.valid_address?(user.email) : user.slack_id.present?
    end

    def create_or_find(user, kind, subject_id, key, now, channel)
      # A savepoint, so a lost race on the unique index does not poison an enclosing transaction.
      Notification.transaction(requires_new: true) do
        Notification.create!(user: user, kind: kind, channel: channel, status: "pending", subject_id: subject_id,
                             scheduled_for: now, due_at: now, idempotency_key: key)
      end
    rescue ActiveRecord::RecordNotUnique
      Notification.find_by(idempotency_key: key)
    end
    private_class_method :create_or_find
  end
end
