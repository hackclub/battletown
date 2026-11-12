# Submitting a ship cancels that project's pending ship reminders by subject_id (Notifications::ShipReminders
# .cancel_pending_for); without this it scanned every pending row (one daily reminder per person). Partial, so it only
# holds the few pending event rows. Built concurrently: notifications keeps months of history in production.
class AddPendingSubjectIndexToNotifications < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :notifications, :subject_id, where: "status = 'pending' AND subject_id IS NOT NULL",
                                           name: "index_notifications_on_pending_subject_id", algorithm: :concurrently
  end
end
