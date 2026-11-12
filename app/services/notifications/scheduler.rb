module Notifications
  # Keeps exactly one pending daily reminder per eligible user in the outbox.
  #
  # Call `Notifications::Scheduler.schedule_next(user)` when onboarding finishes and whenever the user changes their
  # coding days, coding time, time zone or Slack id. It is idempotent: calling it twice (or concurrently) never makes
  # a second row. If the user is no longer eligible (not onboarded, no Slack id, no schedule, or the daily reminder
  # switched off in their preferences) pending rows are cancelled. The dispatcher calls it after each send to queue the following day.
  module Scheduler
    KIND = "daily_reminder"

    module_function

    # What controllers call after a schedule, time zone, Slack id or onboarding change: the same as schedule_next, but
    # a failure is logged (class name only) and swallowed, so a problem here can never break the request.
    def refresh(user)
      schedule_next(user)
    rescue StandardError => e
      Rails.logger.warn("notifications.schedule_failed error=#{e.class.name}")
      nil
    end

    # Returns the pending Notification, or nil when the user is not eligible for reminders.
    def schedule_next(user, now: Time.current)
      scheduled_for = next_instant(user, now)
      cancel_other_pending(user, keep: scheduled_for, now: now)
      return nil unless scheduled_for

      enqueue(user, scheduled_for)
    end

    def next_instant(user, now)
      return nil unless user.onboarded? && user.slack_id.present? && Preferences.enabled?(user, KIND)

      Reminders.due_at(user, after: now)
    end

    def cancel_other_pending(user, keep:, now:)
      scope = Notification.pending.where(user_id: user.id, kind: KIND)
      scope = scope.where.not(scheduled_for: keep) if keep
      scope.update_all(status: "cancelled", updated_at: now)
    end

    def enqueue(user, scheduled_for)
      key = Notification.idempotency_key_for(kind: KIND, user_id: user.id, scheduled_for: scheduled_for)
      row = Notification.find_by(idempotency_key: key) || create_or_find(user, scheduled_for, key)
      revive(row, scheduled_for)
    end

    # The unique indexes (idempotency key, one pending per user and kind) decide any race: the loser re-reads.
    def create_or_find(user, scheduled_for, key)
      Notification.transaction(requires_new: true) do
        Notification.create!(user: user, kind: KIND, channel: "slack_dm", status: "pending",
                             scheduled_for: scheduled_for, due_at: scheduled_for, idempotency_key: key)
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      Notification.find_by(idempotency_key: key) || Notification.pending.find_by(user_id: user.id, kind: KIND)
    end

    # A schedule flipped A -> B -> A cancelled the A row; bring it back instead of colliding with its key.
    # Rows already sent or failed are left alone: that reminder was handled, never send it twice.
    def revive(row, scheduled_for)
      return row unless row&.cancelled? && row.scheduled_for == scheduled_for

      Notification.where(id: row.id, status: "cancelled")
                  .update_all(status: "pending", attempts: 0, last_error_code: nil, due_at: scheduled_for,
                              updated_at: Time.current)
      row.reload
    rescue ActiveRecord::RecordNotUnique
      row.reload
    end
  end
end
