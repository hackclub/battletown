# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_13_010000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "hour_entries", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.date "local_date", null: false
    t.integer "seconds", null: false
    t.string "hackatime_project", limit: 120
    t.string "source", null: false
    t.string "idempotency_key", limit: 120, null: false
    t.string "note", limit: 200
    t.string "created_by", limit: 40
    t.datetime "recorded_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["local_date"], name: "index_hour_entries_on_local_date"
    t.index ["user_id", "idempotency_key"], name: "index_hour_entries_on_user_id_and_idempotency_key", unique: true
    t.index ["user_id", "local_date"], name: "index_hour_entries_on_user_id_and_local_date"
    t.check_constraint "char_length(idempotency_key::text) >= 1 AND char_length(idempotency_key::text) <= 120", name: "hour_entries_idempotency_key_check"
    t.check_constraint "created_by IS NULL OR created_by::text ~ '^[a-z0-9_:.-]{1,40}$'::text", name: "hour_entries_created_by_check"
    t.check_constraint "hackatime_project IS NULL OR char_length(hackatime_project::text) >= 1 AND char_length(hackatime_project::text) <= 120", name: "hour_entries_hackatime_project_check"
    t.check_constraint "note IS NULL OR char_length(note::text) >= 1 AND char_length(note::text) <= 200", name: "hour_entries_note_length_check"
    t.check_constraint "seconds <> 0 AND seconds >= '-86400'::integer AND seconds <= 86400", name: "hour_entries_seconds_check"
    t.check_constraint "source::text = 'adjustment'::text OR seconds > 0", name: "hour_entries_positive_unless_adjustment_check"
    t.check_constraint "source::text = 'hackatime'::text OR note IS NOT NULL", name: "hour_entries_note_required_check"
    t.check_constraint "source::text = ANY (ARRAY['hackatime'::character varying, 'manual'::character varying, 'adjustment'::character varying]::text[])", name: "hour_entries_source_check"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "kind", null: false
    t.string "channel", default: "slack_dm", null: false
    t.string "status", default: "pending", null: false
    t.datetime "scheduled_for", null: false
    t.datetime "due_at", null: false
    t.integer "attempts", default: 0, null: false
    t.string "last_error_code", limit: 40
    t.datetime "sent_at"
    t.string "idempotency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_notifications_on_idempotency_key", unique: true
    t.index ["status", "due_at"], name: "index_notifications_on_status_and_due_at"
    t.index ["user_id", "kind"], name: "index_notifications_one_pending_per_user_kind", unique: true, where: "((status)::text = 'pending'::text)"
    t.index ["user_id"], name: "index_notifications_on_user_id"
    t.check_constraint "attempts >= 0 AND attempts <= 10", name: "notifications_attempts_check"
    t.check_constraint "channel::text = 'slack_dm'::text", name: "notifications_channel_check"
    t.check_constraint "kind::text = 'daily_reminder'::text", name: "notifications_kind_check"
    t.check_constraint "last_error_code IS NULL OR last_error_code::text ~ '^[a-z0-9_]{1,40}$'::text", name: "notifications_last_error_code_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'sent'::character varying, 'failed'::character varying, 'cancelled'::character varying]::text[])", name: "notifications_status_check"
  end

  create_table "privacy_request_tokens", force: :cascade do |t|
    t.string "jti", null: false
    t.string "request_id"
    t.string "action"
    t.boolean "dry_run"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_privacy_request_tokens_on_created_at"
    t.index ["jti"], name: "index_privacy_request_tokens_on_jti", unique: true
    t.check_constraint "action IS NULL OR (action::text = ANY (ARRAY['delete'::character varying, 'export'::character varying]::text[]))", name: "privacy_request_tokens_action_check"
    t.check_constraint "length(jti::text) >= 1 AND length(jti::text) <= 255", name: "privacy_request_tokens_jti_check"
    t.check_constraint "request_id IS NULL OR length(request_id::text) <= 255", name: "privacy_request_tokens_request_id_check"
  end

  create_table "users", force: :cascade do |t|
    t.string "hca_uid", null: false
    t.string "email"
    t.string "display_name"
    t.string "slack_id"
    t.string "verification_status", default: "needs_submission", null: false
    t.boolean "ysws_eligible", default: false, null: false
    t.string "referral_source"
    t.string "prize_key"
    t.string "project_kind"
    t.text "project_idea"
    t.integer "coding_days", default: 0, null: false
    t.string "coding_time"
    t.string "time_zone"
    t.integer "onboarding_step", default: 0, null: false
    t.datetime "onboarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hca_uid"], name: "index_users_on_hca_uid", unique: true
    t.index ["slack_id"], name: "index_users_on_slack_id"
    t.check_constraint "char_length(project_idea) <= 500", name: "users_project_idea_length_check"
    t.check_constraint "coding_days >= 0 AND coding_days <= 127", name: "users_coding_days_check"
    t.check_constraint "coding_time IS NULL OR coding_time::text ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text", name: "users_coding_time_check"
    t.check_constraint "onboarding_step >= 0 AND onboarding_step <= 4", name: "users_onboarding_step_check"
    t.check_constraint "project_kind IS NULL OR (project_kind::text = ANY (ARRAY['game'::character varying, 'website'::character varying, 'app'::character varying, 'tool'::character varying, 'hardware'::character varying, 'undecided'::character varying]::text[]))", name: "users_project_kind_check"
    t.check_constraint "verification_status::text = ANY (ARRAY['needs_submission'::character varying, 'pending'::character varying, 'verified'::character varying, 'ineligible'::character varying]::text[])", name: "users_verification_status_check"
  end

  add_foreign_key "hour_entries", "users", on_delete: :cascade
  add_foreign_key "notifications", "users", on_delete: :cascade
end
