# The hours ledger: append-only rows of coded time, in integer seconds, one per credit. A correction is a new
# `adjustment` row (negative or positive), never an edit. `local_date` is the user's local calendar date, frozen when
# the row is written, so a later time zone change never moves history. Only the Hackatime project NAME is kept (no
# repository, editor, language or file data). Rows go with the user (ON DELETE CASCADE, GDPR erasure), so there is
# deliberately no trigger that blocks deletes. The allowlists are literal so the migration keeps working if the model
# constants change later.
class CreateHourEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :hour_entries do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :local_date, null: false
      t.integer :seconds, null: false
      t.string :hackatime_project, limit: 120
      t.string :source, null: false
      t.string :idempotency_key, null: false, limit: 120
      t.string :note, limit: 200
      t.string :created_by, limit: 40
      t.datetime :recorded_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :hour_entries, [ :user_id, :idempotency_key ], unique: true
    add_index :hour_entries, [ :user_id, :local_date ]
    add_index :hour_entries, :local_date

    add_check_constraint :hour_entries, "source IN ('hackatime', 'manual', 'adjustment')", name: "hour_entries_source_check"
    add_check_constraint :hour_entries, "seconds <> 0 AND seconds BETWEEN -86400 AND 86400", name: "hour_entries_seconds_check"
    add_check_constraint :hour_entries, "source = 'adjustment' OR seconds > 0", name: "hour_entries_positive_unless_adjustment_check"
    add_check_constraint :hour_entries, "source = 'hackatime' OR note IS NOT NULL", name: "hour_entries_note_required_check"
    add_check_constraint :hour_entries, "char_length(idempotency_key) BETWEEN 1 AND 120", name: "hour_entries_idempotency_key_check"
    add_check_constraint :hour_entries, "hackatime_project IS NULL OR char_length(hackatime_project) BETWEEN 1 AND 120",
                         name: "hour_entries_hackatime_project_check"
    add_check_constraint :hour_entries, "note IS NULL OR char_length(note) BETWEEN 1 AND 200", name: "hour_entries_note_length_check"
    add_check_constraint :hour_entries, "created_by IS NULL OR created_by ~ '^[a-z0-9_:.-]{1,40}$'", name: "hour_entries_created_by_check"
  end
end
