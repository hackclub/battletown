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

ActiveRecord::Schema[8.1].define(version: 2026_11_11_200000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
end
