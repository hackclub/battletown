# Event notifications (link question, ship reminders, ship decisions) next to the daily reminder.
#
# - `subject_id`: the row the message is about (a link suggestion, a project or a ship, depending on `kind`). It is
#   a plain number, not a foreign key: the row stays harmless if its subject is deleted (the dispatcher cancels it),
#   and the user cascade still removes everything about a person.
# - Only the daily reminder is limited to one pending row per user; a user can have a reminder for each project.
#   The unique idempotency key is what stops duplicates of the event kinds.
# The allowlist is written out literally so this migration keeps working if the model constants change later.
class AddEventKindsToNotifications < ActiveRecord::Migration[8.1]
  KINDS = %w[daily_reminder link_question ship_reminder ship_mvp ship_approved ship_rejected].freeze

  def up
    add_column :notifications, :subject_id, :bigint

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications, "kind IN (#{KINDS.map { |kind| "'#{kind}'" }.join(', ')})", name: "notifications_kind_check"

    remove_index :notifications, name: "index_notifications_one_pending_per_user_kind"
    add_index :notifications, [ :user_id, :kind ], unique: true, where: "status = 'pending' AND kind = 'daily_reminder'",
              name: "index_notifications_one_pending_per_user_kind"
  end

  def down
    execute "DELETE FROM notifications WHERE kind <> 'daily_reminder'"

    remove_index :notifications, name: "index_notifications_one_pending_per_user_kind"
    add_index :notifications, [ :user_id, :kind ], unique: true, where: "status = 'pending'",
              name: "index_notifications_one_pending_per_user_kind"

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications, "kind IN ('daily_reminder')", name: "notifications_kind_check"

    remove_column :notifications, :subject_id
  end
end
