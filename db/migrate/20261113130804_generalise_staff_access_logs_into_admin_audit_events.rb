# One audit trail for everything staff do (AdminAudit): the NPS "who wrote this" log becomes its first user. The table
# is renamed, not copied, so every existing row and its indexes and foreign key survive untouched (nothing to lose, and
# it reverses exactly). New: `metadata`, a small JSON object of ids, amounts and short staff-written reasons (no personal
# data; AdminAuditEvent enforces the shape), and an index for the audit page's filters.
class GeneraliseStaffAccessLogsIntoAdminAuditEvents < ActiveRecord::Migration[8.1]
  def change
    rename_table :staff_access_logs, :admin_audit_events
    add_column :admin_audit_events, :metadata, :jsonb, null: false, default: {}
    add_check_constraint :admin_audit_events, "jsonb_typeof(metadata) = 'object'", name: "admin_audit_events_metadata_object_check"
    add_index :admin_audit_events, [ :action, :created_at ]
    add_index :admin_audit_events, [ :actor_id, :created_at ]
  end
end
