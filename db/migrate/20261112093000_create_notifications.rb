# Outbox for outbound notifications (Slack DMs first). No message text and no recipient address is stored: the text
# is built from `kind` at send time (config/notifications.yml) and the recipient is read from users.slack_id, so the
# table holds no free text or contact data. Rows are deleted with the user (ON DELETE CASCADE, GDPR erasure).
# The allowlists are written out literally so this migration keeps working if the model constants change later.
class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.string :kind, null: false
      t.string :channel, null: false, default: "slack_dm"
      t.string :status, null: false, default: "pending"
      # The natural reminder instant (what the user's schedule asked for) and when we will next try to send it
      # (moves for quiet hours and retry backoff).
      t.datetime :scheduled_for, null: false
      t.datetime :due_at, null: false
      t.integer :attempts, null: false, default: 0
      t.string :last_error_code, limit: 40
      t.datetime :sent_at
      t.string :idempotency_key, null: false
      t.timestamps
    end

    add_index :notifications, :idempotency_key, unique: true
    add_index :notifications, [ :status, :due_at ]
    # At most one pending notification per user and kind, so a double enqueue can never double send.
    add_index :notifications, [ :user_id, :kind ], unique: true, where: "status = 'pending'",
              name: "index_notifications_one_pending_per_user_kind"

    add_check_constraint :notifications, "kind IN ('daily_reminder')", name: "notifications_kind_check"
    add_check_constraint :notifications, "channel IN ('slack_dm')", name: "notifications_channel_check"
    add_check_constraint :notifications, "status IN ('pending', 'sent', 'failed', 'cancelled')",
                         name: "notifications_status_check"
    add_check_constraint :notifications, "attempts BETWEEN 0 AND 10", name: "notifications_attempts_check"
    add_check_constraint :notifications, "last_error_code IS NULL OR last_error_code ~ '^[a-z0-9_]{1,40}$'",
                         name: "notifications_last_error_code_check"
  end
end
