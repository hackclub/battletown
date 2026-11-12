# A ship: a teen submits the coded time on one project (since their last ship) for staff review. The window is
# snapshotted when it is submitted (coded_seconds, the local dates it covers and the seconds per date), so later hours
# belong to the next ship. Coins are not stored here: approval writes Coins::Ledger rows that reference the ship.
#
# Deleted with the user (user_id cascade) and with the project (composite key, so a ship's user is always its
# project's owner). reviewer_id is a staff member, not the subject: it is nulled when that staff user is deleted.
class CreateShips < ActiveRecord::Migration[8.1]
  URL = "[^[:space:]/?#@]".freeze

  def change
    create_table :ships do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :project_id, null: false
      t.string :status, null: false, default: "draft"
      t.text :description
      t.string :repo_url
      t.string :demo_url
      t.integer :coded_seconds, null: false
      t.date :window_start_date, null: false
      t.date :window_end_date, null: false
      t.jsonb :daily_seconds, null: false, default: {}
      t.integer :approved_seconds
      t.references :reviewer, foreign_key: { to_table: :users, on_delete: :nullify }, index: false
      t.datetime :reviewed_at
      t.string :rejection_reason, limit: 300
      t.string :payout_note, limit: 300
      t.datetime :submitted_at
      t.timestamps
    end

    add_index :ships, [ :user_id, :created_at ]
    add_index :ships, :project_id
    add_index :ships, [ :status, :submitted_at ]
    add_index :ships, :reviewer_id
    # One open (draft or submitted) ship per project, whatever the application does.
    add_index :ships, :project_id, unique: true, where: "status IN ('draft', 'submitted')", name: "index_ships_one_open_per_project"
    # Composite so a ship's user is always its project's owner; cascades when the project (or the user) goes.
    add_foreign_key :ships, :projects, column: [ :project_id, :user_id ], primary_key: [ :id, :user_id ], on_delete: :cascade

    add_check_constraint :ships, "status IN ('draft', 'submitted', 'approved', 'rejected', 'withdrawn')", name: "ships_status_check"
    add_check_constraint :ships, "description IS NULL OR char_length(description) <= 1000", name: "ships_description_length_check"
    add_check_constraint :ships, "status = 'draft' OR (description IS NOT NULL AND char_length(btrim(description)) >= 1)", name: "ships_description_required_check"
    add_check_constraint :ships, "repo_url IS NULL OR char_length(repo_url) <= 300 AND repo_url ~ '^https://github\\.com/[a-z0-9-]{1,39}/(?!\\.+$)[a-z0-9._-]{1,100}$'", name: "ships_repo_url_check"
    add_check_constraint :ships, "status = 'draft' OR repo_url IS NOT NULL", name: "ships_repo_required_check"
    add_check_constraint :ships, "demo_url IS NULL OR char_length(demo_url) <= 300 AND demo_url ~ '^https://#{URL}+([/?#][^[:space:]]*)?$'", name: "ships_demo_url_check"
    add_check_constraint :ships, "coded_seconds > 0", name: "ships_coded_seconds_check"
    add_check_constraint :ships, "window_end_date >= window_start_date", name: "ships_window_dates_check"
    # Approved hours exist exactly when the ship is approved, and never exceed what was coded.
    add_check_constraint :ships, "(status = 'approved') = (approved_seconds IS NOT NULL)", name: "ships_approved_seconds_presence_check"
    add_check_constraint :ships, "approved_seconds IS NULL OR (approved_seconds > 0 AND approved_seconds <= coded_seconds)", name: "ships_approved_seconds_range_check"
    add_check_constraint :ships, "(status = 'rejected') = (rejection_reason IS NOT NULL)", name: "ships_rejection_reason_presence_check"
    add_check_constraint :ships, "rejection_reason IS NULL OR char_length(btrim(rejection_reason)) >= 1", name: "ships_rejection_reason_blank_check"
    add_check_constraint :ships, "status NOT IN ('approved', 'rejected') OR reviewed_at IS NOT NULL", name: "ships_reviewed_at_check"
    add_check_constraint :ships, "status = 'draft' OR submitted_at IS NOT NULL", name: "ships_submitted_at_check"
    add_check_constraint :ships, "payout_note IS NULL OR status = 'approved'", name: "ships_payout_note_check"
    add_check_constraint :ships, "jsonb_typeof(daily_seconds) = 'object'", name: "ships_daily_seconds_check"
  end
end
