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

ActiveRecord::Schema[8.1].define(version: 2026_11_13_150001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admin_audit_events", force: :cascade do |t|
    t.bigint "actor_id"
    t.string "action", limit: 60, null: false
    t.string "subject_type", limit: 60, null: false
    t.bigint "subject_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.index ["action", "created_at"], name: "index_admin_audit_events_on_action_and_created_at"
    t.index ["actor_id", "created_at"], name: "index_admin_audit_events_on_actor_id_and_created_at"
    t.index ["actor_id"], name: "index_admin_audit_events_on_actor_id"
    t.index ["created_at"], name: "index_admin_audit_events_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_admin_audit_events_on_subject_type_and_subject_id"
    t.check_constraint "jsonb_typeof(metadata) = 'object'::text", name: "admin_audit_events_metadata_object_check"
  end

  create_table "bosses", force: :cascade do |t|
    t.string "name", limit: 60, null: false
    t.string "art_key", limit: 40, null: false
    t.date "starts_on", null: false
    t.date "ends_on", null: false
    t.integer "hp_seconds", null: false
    t.datetime "defeated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["starts_on"], name: "index_bosses_on_starts_on", unique: true
    t.check_constraint "art_key::text ~ '^[a-z0-9_-]{1,40}$'::text", name: "bosses_art_key_check"
    t.check_constraint "char_length(btrim(name::text)) >= 1 AND char_length(btrim(name::text)) <= 60", name: "bosses_name_check"
    t.check_constraint "ends_on >= starts_on", name: "bosses_dates_check"
    t.check_constraint "hp_seconds >= 1 AND hp_seconds <= 360000000", name: "bosses_hp_seconds_check"
    t.exclusion_constraint "daterange(starts_on, ends_on, '[]'::text) WITH &&", using: :gist, name: "bosses_no_overlap"
  end

  create_table "coin_transactions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "amount", null: false
    t.string "kind", null: false
    t.string "reference_type", limit: 60
    t.bigint "reference_id"
    t.string "idempotency_key", limit: 120, null: false
    t.string "note", limit: 200
    t.string "created_by", limit: 40
    t.datetime "created_at", null: false
    t.index ["reference_type", "reference_id"], name: "index_coin_transactions_on_reference_type_and_reference_id"
    t.index ["user_id", "created_at"], name: "index_coin_transactions_on_user_id_and_created_at"
    t.index ["user_id", "idempotency_key"], name: "index_coin_transactions_on_user_id_and_idempotency_key", unique: true
    t.check_constraint "(kind::text = ANY (ARRAY['ship_approval'::character varying, 'streak_bonus'::character varying, 'refund'::character varying, 'quest_reward'::character varying, 'team_bonus'::character varying]::text[])) AND amount > 0 OR kind::text = 'purchase'::text AND amount < 0 OR kind::text = 'adjustment'::text", name: "coin_transactions_sign_check"
    t.check_constraint "(reference_type IS NULL) = (reference_id IS NULL)", name: "coin_transactions_reference_check"
    t.check_constraint "amount <> 0", name: "coin_transactions_amount_check"
    t.check_constraint "char_length(idempotency_key::text) >= 1 AND char_length(idempotency_key::text) <= 120", name: "coin_transactions_idempotency_key_check"
    t.check_constraint "created_by IS NULL OR created_by::text ~ '^[a-z0-9_:.-]{1,40}$'::text", name: "coin_transactions_created_by_check"
    t.check_constraint "kind::text = ANY (ARRAY['ship_approval'::character varying, 'streak_bonus'::character varying, 'purchase'::character varying, 'refund'::character varying, 'adjustment'::character varying, 'quest_reward'::character varying, 'team_bonus'::character varying]::text[])", name: "coin_transactions_kind_check"
    t.check_constraint "note IS NULL OR char_length(note::text) <= 200", name: "coin_transactions_note_check"
  end

  create_table "daily_results", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.date "local_date", null: false
    t.integer "raw_seconds", null: false
    t.boolean "quick_met", null: false
    t.boolean "goal_met", null: false
    t.boolean "freeze_used", default: false, null: false
    t.integer "streak_15", null: false
    t.integer "goal_streak", null: false
    t.boolean "freeze_available", null: false
    t.integer "days_since_freeze", default: 0, null: false
    t.integer "bonus_bps", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["user_id", "local_date"], name: "index_daily_results_on_user_id_and_local_date", unique: true
    t.check_constraint "NOT (bonus_bps > 0 AND NOT quick_met)", name: "daily_results_bonus_needs_quick_check"
    t.check_constraint "NOT (bonus_bps > 0 AND streak_15 = 0)", name: "daily_results_bonus_needs_streak_check"
    t.check_constraint "NOT (freeze_used AND bonus_bps > 0)", name: "daily_results_freeze_no_bonus_check"
    t.check_constraint "NOT (freeze_used AND freeze_available)", name: "daily_results_freeze_spent_check"
    t.check_constraint "NOT (freeze_used AND quick_met)", name: "daily_results_freeze_not_on_met_day_check"
    t.check_constraint "NOT (freeze_used AND streak_15 = 0)", name: "daily_results_freeze_needs_streak_check"
    t.check_constraint "bonus_bps >= 0 AND bonus_bps <= 10000", name: "daily_results_bonus_bps_check"
    t.check_constraint "raw_seconds >= 0 AND raw_seconds <= 86400", name: "daily_results_raw_seconds_check"
    t.check_constraint "streak_15 >= 0 AND goal_streak >= 0 AND days_since_freeze >= 0", name: "daily_results_counters_check"
  end

  create_table "flipper_features", force: :cascade do |t|
    t.string "key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_flipper_features_on_key", unique: true
  end

  create_table "flipper_gates", force: :cascade do |t|
    t.string "feature_key", null: false
    t.string "key", null: false
    t.text "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feature_key", "key", "value"], name: "index_flipper_gates_on_feature_key_and_key_and_value", unique: true
  end

  create_table "hackatime_connections", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "hackatime_uid", null: false
    t.text "access_token", null: false
    t.text "refresh_token"
    t.string "scopes", default: "", null: false
    t.datetime "expires_at"
    t.datetime "connected_at", null: false
    t.datetime "last_synced_at"
    t.string "last_error_code", limit: 40
    t.boolean "needs_reconnect", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hackatime_uid"], name: "index_hackatime_connections_on_hackatime_uid", unique: true
    t.index ["user_id"], name: "index_hackatime_connections_on_user_id", unique: true
    t.check_constraint "char_length(access_token) <= 4000", name: "hackatime_connections_access_token_length_check"
    t.check_constraint "char_length(hackatime_uid::text) >= 1 AND char_length(hackatime_uid::text) <= 40", name: "hackatime_connections_uid_length_check"
    t.check_constraint "char_length(scopes::text) <= 100", name: "hackatime_connections_scopes_length_check"
    t.check_constraint "last_error_code IS NULL OR last_error_code::text ~ '^[a-z0-9_]{1,40}$'::text", name: "hackatime_connections_last_error_code_check"
    t.check_constraint "refresh_token IS NULL OR char_length(refresh_token) <= 4000", name: "hackatime_connections_refresh_token_length_check"
  end

  create_table "hackatime_day_windows", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.date "local_date", null: false
    t.datetime "starts_at", null: false
    t.datetime "ends_at", null: false
    t.string "hackatime_uid", limit: 40, null: false
    t.datetime "created_at", null: false
    t.index ["hackatime_uid", "ends_at"], name: "index_hackatime_day_windows_on_hackatime_uid_and_ends_at"
    t.index ["user_id", "local_date"], name: "index_hackatime_day_windows_on_user_id_and_local_date", unique: true
    t.check_constraint "char_length(hackatime_uid::text) >= 1 AND char_length(hackatime_uid::text) <= 40", name: "hackatime_day_windows_uid_length_check"
    t.check_constraint "ends_at >= starts_at", name: "hackatime_day_windows_order_check"
  end

  create_table "hackatime_links", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "project_id", null: false
    t.string "hackatime_project", null: false
    t.string "link_method", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_hackatime_links_on_project_id"
    t.index ["user_id", "hackatime_project"], name: "index_hackatime_links_on_user_and_name", unique: true
    t.check_constraint "char_length(hackatime_project::text) >= 1 AND char_length(hackatime_project::text) <= 120 AND hackatime_project::text !~ '[[:cntrl:]]'::text AND hackatime_project::text = btrim(hackatime_project::text)", name: "hackatime_links_name_check"
    t.check_constraint "link_method::text = ANY (ARRAY['manual'::character varying, 'auto_repo'::character varying, 'confirmed'::character varying]::text[])", name: "hackatime_links_method_check"
  end

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

  create_table "link_suggestions", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.string "hackatime_project", null: false
    t.string "state", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "hackatime_project"], name: "index_link_suggestions_on_project_and_name", unique: true
    t.check_constraint "char_length(hackatime_project::text) >= 1 AND char_length(hackatime_project::text) <= 120 AND hackatime_project::text !~ '[[:cntrl:]]'::text AND hackatime_project::text = btrim(hackatime_project::text)", name: "link_suggestions_name_check"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying, 'accepted'::character varying, 'declined'::character varying]::text[])", name: "link_suggestions_state_check"
  end

  create_table "merch_claims", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "boss_id", null: false
    t.string "item_key", limit: 60, null: false
    t.string "item_name", limit: 100, null: false
    t.string "status", default: "requested", null: false
    t.datetime "claimed_at", null: false
    t.datetime "fulfilled_at"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["boss_id"], name: "index_merch_claims_on_boss_id"
    t.index ["status", "claimed_at"], name: "index_merch_claims_on_status_and_claimed_at"
    t.index ["user_id", "boss_id"], name: "index_merch_claims_on_user_id_and_boss_id", unique: true
    t.check_constraint "(status::text = 'cancelled'::text) = (cancelled_at IS NOT NULL)", name: "merch_claims_cancelled_at_check"
    t.check_constraint "(status::text = 'fulfilled'::text) = (fulfilled_at IS NOT NULL)", name: "merch_claims_fulfilled_at_check"
    t.check_constraint "char_length(item_key::text) >= 1 AND char_length(item_name::text) >= 1", name: "merch_claims_item_check"
    t.check_constraint "status::text = ANY (ARRAY['requested'::character varying, 'fulfilled'::character varying, 'cancelled'::character varying]::text[])", name: "merch_claims_status_check"
  end

  create_table "notification_preferences", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "kind", null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "channel", default: "slack_dm", null: false
    t.index ["user_id", "kind", "channel"], name: "index_notification_preferences_on_user_kind_channel", unique: true
    t.check_constraint "channel::text = ANY (ARRAY['slack_dm'::character varying, 'email'::character varying]::text[])", name: "notification_preferences_channel_check"
    t.check_constraint "kind::text = ANY (ARRAY['daily_reminder'::character varying, 'link_question'::character varying, 'ship_reminder'::character varying, 'ship_mvp'::character varying, 'ship_approved'::character varying, 'ship_rejected'::character varying, 'returning_nudge'::character varying, 'nps_prompt'::character varying, 'order_shipped'::character varying, 'order_fulfilled'::character varying, 'order_cancelled'::character varying, 'order_refunded'::character varying]::text[])", name: "notification_preferences_kind_check"
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
    t.bigint "subject_id"
    t.index ["idempotency_key"], name: "index_notifications_on_idempotency_key", unique: true
    t.index ["subject_id"], name: "index_notifications_on_pending_subject_id", where: "(((status)::text = 'pending'::text) AND (subject_id IS NOT NULL))"
    t.index ["status", "due_at"], name: "index_notifications_on_status_and_due_at"
    t.index ["user_id", "kind"], name: "index_notifications_one_pending_per_user_kind", unique: true, where: "(((status)::text = 'pending'::text) AND ((kind)::text = 'daily_reminder'::text))"
    t.index ["user_id"], name: "index_notifications_on_user_id"
    t.check_constraint "attempts >= 0 AND attempts <= 10", name: "notifications_attempts_check"
    t.check_constraint "channel::text = ANY (ARRAY['slack_dm'::character varying, 'email'::character varying]::text[])", name: "notifications_channel_check"
    t.check_constraint "kind::text = ANY (ARRAY['daily_reminder'::character varying, 'link_question'::character varying, 'ship_reminder'::character varying, 'ship_mvp'::character varying, 'ship_approved'::character varying, 'ship_rejected'::character varying, 'returning_nudge'::character varying, 'nps_prompt'::character varying, 'order_shipped'::character varying, 'order_fulfilled'::character varying, 'order_cancelled'::character varying, 'order_refunded'::character varying]::text[])", name: "notifications_kind_check"
    t.check_constraint "last_error_code IS NULL OR last_error_code::text ~ '^[a-z0-9_]{1,40}$'::text", name: "notifications_last_error_code_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'sent'::character varying, 'failed'::character varying, 'cancelled'::character varying, 'skipped'::character varying]::text[])", name: "notifications_status_check"
  end

  create_table "nps_responses", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "score", null: false
    t.string "comment", limit: 300
    t.datetime "answered_at", null: false
    t.date "prompt_window_date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["answered_at"], name: "index_nps_responses_on_answered_at"
    t.index ["user_id", "prompt_window_date"], name: "index_nps_responses_on_user_id_and_prompt_window_date", unique: true
    t.check_constraint "comment IS NULL OR char_length(comment::text) <= 300", name: "nps_responses_comment_length_check"
    t.check_constraint "score >= 0 AND score <= 10", name: "nps_responses_score_check"
  end

  create_table "order_events", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "actor_id"
    t.string "actor_kind", limit: 10, null: false
    t.string "action", limit: 20, null: false
    t.string "from_status", limit: 20
    t.string "to_status", limit: 20
    t.string "reason_code", limit: 30
    t.string "note", limit: 300
    t.datetime "created_at", null: false
    t.index ["actor_id"], name: "index_order_events_on_actor_id", where: "(actor_id IS NOT NULL)"
    t.index ["order_id", "created_at"], name: "index_order_events_on_order_id_and_created_at"
    t.check_constraint "action::text = ANY (ARRAY['held'::character varying, 'released'::character varying, 'shipped'::character varying, 'fulfilled'::character varying, 'cancelled'::character varying, 'refunded'::character varying, 'tracking_updated'::character varying, 'note_added'::character varying]::text[])", name: "order_events_action_check"
    t.check_constraint "actor_kind::text = 'staff'::text OR actor_id IS NULL", name: "order_events_actor_check"
    t.check_constraint "actor_kind::text = ANY (ARRAY['buyer'::character varying, 'staff'::character varying, 'system'::character varying]::text[])", name: "order_events_actor_kind_check"
    t.check_constraint "from_status IS NULL OR (from_status::text = ANY (ARRAY['requested'::character varying, 'on_hold'::character varying, 'shipped'::character varying, 'fulfilled'::character varying, 'cancelled'::character varying, 'refunded'::character varying]::text[]))", name: "order_events_from_status_check"
    t.check_constraint "note IS NULL OR char_length(note::text) >= 1 AND char_length(note::text) <= 300 AND note::text !~ '[[:cntrl:]]'::text", name: "order_events_note_check"
    t.check_constraint "reason_code IS NULL OR reason_code::text ~ '^[a-z_]{2,30}$'::text", name: "order_events_reason_code_check"
    t.check_constraint "to_status IS NULL OR (to_status::text = ANY (ARRAY['requested'::character varying, 'on_hold'::character varying, 'shipped'::character varying, 'fulfilled'::character varying, 'cancelled'::character varying, 'refunded'::character varying]::text[]))", name: "order_events_to_status_check"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "prize_key", limit: 60, null: false
    t.string "prize_name", limit: 100, null: false
    t.integer "coins", null: false
    t.string "kind", null: false
    t.string "status", default: "requested", null: false
    t.string "idempotency_key", limit: 100, null: false
    t.datetime "fulfilled_at"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "shipped_at"
    t.datetime "refunded_at"
    t.string "tracking_carrier", limit: 20
    t.string "tracking_number", limit: 60
    t.string "tracking_label", limit: 40
    t.index ["status", "created_at"], name: "index_orders_on_status_and_created_at"
    t.index ["user_id", "created_at"], name: "index_orders_on_user_id_and_created_at"
    t.index ["user_id", "idempotency_key"], name: "index_orders_on_user_id_and_idempotency_key", unique: true
    t.index ["user_id"], name: "index_orders_one_signup_sticker_per_user", unique: true, where: "((kind)::text = 'signup_sticker'::text)"
    t.check_constraint "(status::text <> 'fulfilled'::text OR fulfilled_at IS NOT NULL) AND (fulfilled_at IS NULL OR (status::text = ANY (ARRAY['fulfilled'::character varying, 'refunded'::character varying]::text[])))", name: "orders_fulfilled_at_check"
    t.check_constraint "(status::text = 'cancelled'::text) = (cancelled_at IS NOT NULL)", name: "orders_cancelled_at_check"
    t.check_constraint "(status::text = 'refunded'::text) = (refunded_at IS NOT NULL)", name: "orders_refunded_at_check"
    t.check_constraint "(tracking_carrier IS NULL) = (tracking_number IS NULL)", name: "orders_tracking_pair_check"
    t.check_constraint "char_length(idempotency_key::text) >= 1 AND char_length(idempotency_key::text) <= 100", name: "orders_idempotency_key_check"
    t.check_constraint "char_length(prize_key::text) >= 1 AND char_length(prize_name::text) >= 1", name: "orders_prize_check"
    t.check_constraint "coins >= 0", name: "orders_coins_check"
    t.check_constraint "kind::text = 'signup_sticker'::text AND coins = 0 OR kind::text = 'purchase'::text AND coins > 0", name: "orders_kind_coins_check"
    t.check_constraint "kind::text = ANY (ARRAY['purchase'::character varying, 'signup_sticker'::character varying]::text[])", name: "orders_kind_check"
    t.check_constraint "shipped_at IS NULL OR (status::text = ANY (ARRAY['shipped'::character varying, 'fulfilled'::character varying, 'refunded'::character varying]::text[]))", name: "orders_shipped_at_status_check"
    t.check_constraint "status::text <> 'shipped'::text OR shipped_at IS NOT NULL", name: "orders_shipped_at_check"
    t.check_constraint "status::text = ANY (ARRAY['requested'::character varying, 'on_hold'::character varying, 'shipped'::character varying, 'fulfilled'::character varying, 'cancelled'::character varying, 'refunded'::character varying]::text[])", name: "orders_status_check"
    t.check_constraint "tracking_carrier IS NULL OR tracking_carrier::text ~ '^[a-z_]{2,20}$'::text", name: "orders_tracking_carrier_check"
    t.check_constraint "tracking_label IS NULL OR tracking_carrier::text = 'other'::text AND char_length(tracking_label::text) >= 1 AND char_length(tracking_label::text) <= 40 AND tracking_label::text !~ '[[:cntrl:]]'::text", name: "orders_tracking_label_check"
    t.check_constraint "tracking_number IS NULL OR tracking_number::text ~ '^[A-Za-z0-9][A-Za-z0-9 -]{2,59}$'::text AND shipped_at IS NOT NULL", name: "orders_tracking_number_check"
  end

  create_table "plinko_drops", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.datetime "dropped_at", null: false
    t.date "local_date", null: false
    t.integer "slot", null: false
    t.integer "points", null: false
    t.bigint "seed", null: false
    t.string "idempotency_key", limit: 64, null: false
    t.index ["local_date"], name: "index_plinko_drops_on_local_date"
    t.index ["user_id", "dropped_at"], name: "index_plinko_drops_on_user_id_and_dropped_at"
    t.index ["user_id", "idempotency_key"], name: "index_plinko_drops_on_user_id_and_idempotency_key", unique: true
    t.check_constraint "char_length(idempotency_key::text) >= 8 AND char_length(idempotency_key::text) <= 64", name: "plinko_drops_key_length_check"
    t.check_constraint "points >= 0", name: "plinko_drops_points_check"
    t.check_constraint "slot >= 0", name: "plinko_drops_slot_check"
  end

  create_table "plinko_players", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "nickname", limit: 40, null: false
    t.boolean "leaderboard_opt_in", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((nickname)::text)", name: "index_plinko_players_on_lower_nickname", unique: true
    t.index ["leaderboard_opt_in"], name: "index_plinko_players_on_opt_in", where: "leaderboard_opt_in"
    t.index ["user_id"], name: "index_plinko_players_on_user_id", unique: true
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

  create_table "project_reviews", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.bigint "reviewer_id"
    t.string "status", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.index ["project_id", "created_at"], name: "index_project_reviews_on_project_id_and_created_at", order: { created_at: :desc }
    t.index ["reviewer_id"], name: "index_project_reviews_on_reviewer_id"
    t.check_constraint "note IS NULL OR char_length(note) <= 500", name: "project_reviews_note_length_check"
    t.check_constraint "status::text <> 'flagged'::text OR note IS NOT NULL AND note ~ '[^[:space:]]'::text", name: "project_reviews_flag_needs_note_check"
    t.check_constraint "status::text = ANY (ARRAY['ok'::character varying, 'flagged'::character varying]::text[])", name: "project_reviews_status_check"
  end

  create_table "projects", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.string "kind", default: "undecided", null: false
    t.text "idea"
    t.string "repo_url"
    t.string "demo_url"
    t.string "status", default: "active", null: false
    t.string "guide_key"
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "review_status", default: "unreviewed", null: false
    t.datetime "reviewed_at"
    t.index ["id", "user_id"], name: "index_projects_on_id_and_user_id", unique: true
    t.index ["review_status", "created_at"], name: "index_projects_on_review_status_and_created_at"
    t.index ["user_id", "created_at"], name: "index_projects_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_projects_one_active_per_user", unique: true, where: "active"
    t.check_constraint "(review_status::text = 'unreviewed'::text) = (reviewed_at IS NULL)", name: "projects_reviewed_at_check"
    t.check_constraint "NOT active OR status::text = 'active'::text", name: "projects_active_not_archived_check"
    t.check_constraint "char_length(idea) <= 500", name: "projects_idea_length_check"
    t.check_constraint "char_length(name::text) >= 1 AND char_length(name::text) <= 60 AND btrim(name::text) <> ''::text", name: "projects_name_check"
    t.check_constraint "demo_url IS NULL OR char_length(demo_url::text) <= 300 AND demo_url::text ~ '^https://[^[:space:]/?\#@]+([/?#][^[:space:]]*)?$'::text", name: "projects_demo_url_check"
    t.check_constraint "guide_key IS NULL OR (guide_key::text = ANY (ARRAY['sd'::character varying, 'playground'::character varying]::text[]))", name: "projects_guide_key_check"
    t.check_constraint "kind::text = ANY (ARRAY['game'::character varying, 'website'::character varying, 'app'::character varying, 'tool'::character varying, 'hardware'::character varying, 'undecided'::character varying]::text[])", name: "projects_kind_check"
    t.check_constraint "repo_url IS NULL OR char_length(repo_url::text) <= 300 AND repo_url::text ~ '^https://github\\.com/[a-z0-9-]{1,39}/(?!\\.+$)[a-z0-9._-]{1,100}$'::text", name: "projects_repo_url_check"
    t.check_constraint "review_status::text = ANY (ARRAY['unreviewed'::character varying, 'ok'::character varying, 'flagged'::character varying]::text[])", name: "projects_review_status_check"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying, 'archived'::character varying]::text[])", name: "projects_status_check"
  end

  create_table "quest_completions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "quest_id", null: false
    t.datetime "completed_at", null: false
    t.bigint "coin_transaction_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["coin_transaction_id"], name: "index_quest_completions_on_coin_transaction_id"
    t.index ["quest_id"], name: "index_quest_completions_on_quest_id"
    t.index ["user_id", "quest_id"], name: "index_quest_completions_on_user_id_and_quest_id", unique: true
    t.index ["user_id"], name: "index_quest_completions_pending_by_user", where: "(coin_transaction_id IS NULL)"
  end

  create_table "quests", force: :cascade do |t|
    t.date "starts_on", null: false
    t.date "ends_on", null: false
    t.string "goal_key", limit: 40, null: false
    t.jsonb "goal_params", default: {}, null: false
    t.integer "reward_coins", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["starts_on"], name: "index_quests_on_starts_on", unique: true
    t.check_constraint "ends_on >= starts_on", name: "quests_dates_check"
    t.check_constraint "goal_key::text = ANY (ARRAY['code_days'::character varying, 'streak_days'::character varying, 'ship_project'::character varying, 'link_hackatime'::character varying, 'add_project'::character varying]::text[])", name: "quests_goal_key_check"
    t.check_constraint "jsonb_typeof(goal_params) = 'object'::text", name: "quests_goal_params_check"
    t.check_constraint "reward_coins >= 1 AND reward_coins <= 1000", name: "quests_reward_coins_check"
  end

  create_table "ship_images", force: :cascade do |t|
    t.bigint "ship_id", null: false
    t.bigint "user_id", null: false
    t.integer "position", null: false
    t.binary "content", null: false
    t.integer "width", null: false
    t.integer "height", null: false
    t.integer "byte_size", null: false
    t.string "sha256", limit: 64, null: false
    t.string "alt", limit: 140
    t.datetime "created_at", null: false
    t.index ["ship_id", "position"], name: "index_ship_images_on_ship_id_and_position", unique: true
    t.index ["ship_id", "sha256"], name: "index_ship_images_on_ship_id_and_sha256", unique: true
    t.index ["user_id"], name: "index_ship_images_on_user_id"
    t.check_constraint "\"position\" >= 1 AND \"position\" <= 3", name: "ship_images_position_check"
    t.check_constraint "alt IS NULL OR char_length(alt::text) <= 140", name: "ship_images_alt_check"
    t.check_constraint "byte_size >= 1 AND byte_size <= 5000000", name: "ship_images_byte_size_check"
    t.check_constraint "octet_length(content) = byte_size", name: "ship_images_content_size_check"
    t.check_constraint "sha256::text ~ '^[0-9a-f]{64}$'::text", name: "ship_images_sha256_check"
    t.check_constraint "width > 0 AND height > 0", name: "ship_images_dimensions_check"
  end

  create_table "ships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "project_id", null: false
    t.string "status", default: "draft", null: false
    t.text "description"
    t.string "repo_url"
    t.string "demo_url"
    t.integer "coded_seconds", null: false
    t.date "window_start_date", null: false
    t.date "window_end_date", null: false
    t.jsonb "daily_seconds", default: {}, null: false
    t.integer "approved_seconds"
    t.bigint "reviewer_id"
    t.datetime "reviewed_at"
    t.string "rejection_reason", limit: 300
    t.string "payout_note", limit: 300
    t.datetime "submitted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "hackatime_projects", default: [], null: false, array: true
    t.index ["project_id"], name: "index_ships_on_project_id"
    t.index ["project_id"], name: "index_ships_one_open_per_project", unique: true, where: "((status)::text = ANY ((ARRAY['draft'::character varying, 'submitted'::character varying])::text[]))"
    t.index ["reviewer_id"], name: "index_ships_on_reviewer_id"
    t.index ["status", "submitted_at"], name: "index_ships_on_status_and_submitted_at"
    t.index ["user_id", "created_at"], name: "index_ships_on_user_id_and_created_at"
    t.check_constraint "(status::text <> ALL (ARRAY['approved'::character varying, 'rejected'::character varying]::text[])) OR reviewed_at IS NOT NULL", name: "ships_reviewed_at_check"
    t.check_constraint "(status::text = 'approved'::text) = (approved_seconds IS NOT NULL)", name: "ships_approved_seconds_presence_check"
    t.check_constraint "(status::text = 'rejected'::text) = (rejection_reason IS NOT NULL)", name: "ships_rejection_reason_presence_check"
    t.check_constraint "approved_seconds IS NULL OR approved_seconds > 0 AND approved_seconds <= coded_seconds", name: "ships_approved_seconds_range_check"
    t.check_constraint "coded_seconds > 0", name: "ships_coded_seconds_check"
    t.check_constraint "demo_url IS NULL OR char_length(demo_url::text) <= 300 AND demo_url::text ~ '^https://[^[:space:]/?\#@]+([/?#][^[:space:]]*)?$'::text", name: "ships_demo_url_check"
    t.check_constraint "description IS NULL OR char_length(description) <= 1000", name: "ships_description_length_check"
    t.check_constraint "jsonb_typeof(daily_seconds) = 'object'::text", name: "ships_daily_seconds_check"
    t.check_constraint "payout_note IS NULL OR status::text = 'approved'::text", name: "ships_payout_note_check"
    t.check_constraint "rejection_reason IS NULL OR char_length(btrim(rejection_reason::text)) >= 1", name: "ships_rejection_reason_blank_check"
    t.check_constraint "repo_url IS NULL OR char_length(repo_url::text) <= 300 AND repo_url::text ~ '^https://github\\.com/[a-z0-9-]{1,39}/(?!\\.+$)[a-z0-9._-]{1,100}$'::text", name: "ships_repo_url_check"
    t.check_constraint "status::text = 'draft'::text OR description IS NOT NULL AND char_length(btrim(description)) >= 1", name: "ships_description_required_check"
    t.check_constraint "status::text = 'draft'::text OR repo_url IS NOT NULL", name: "ships_repo_required_check"
    t.check_constraint "status::text = 'draft'::text OR submitted_at IS NOT NULL", name: "ships_submitted_at_check"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'submitted'::character varying, 'approved'::character varying, 'rejected'::character varying, 'withdrawn'::character varying]::text[])", name: "ships_status_check"
    t.check_constraint "window_end_date >= window_start_date", name: "ships_window_dates_check"
  end

  create_table "shop_items", force: :cascade do |t|
    t.string "key", limit: 60, null: false
    t.string "name", limit: 60, null: false
    t.string "description", limit: 200, default: "", null: false
    t.string "emoji", limit: 8
    t.integer "coins", null: false
    t.string "tier", default: "shop", null: false
    t.string "kind", default: "regular", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.binary "image_content"
    t.integer "image_width"
    t.integer "image_height"
    t.integer "image_byte_size"
    t.string "image_sha256", limit: 64
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active", "position"], name: "index_shop_items_on_active_and_position"
    t.index ["key"], name: "index_shop_items_on_key", unique: true
    t.index ["kind"], name: "index_shop_items_one_free_signup", unique: true, where: "((kind)::text = 'free_signup'::text)"
    t.check_constraint "\"position\" >= 0", name: "shop_items_position_check"
    t.check_constraint "char_length(btrim(name::text)) >= 1 AND char_length(btrim(name::text)) <= 60", name: "shop_items_name_check"
    t.check_constraint "char_length(description::text) <= 200", name: "shop_items_description_check"
    t.check_constraint "coins >= 0", name: "shop_items_coins_check"
    t.check_constraint "emoji IS NULL OR char_length(emoji::text) >= 1 AND char_length(emoji::text) <= 8", name: "shop_items_emoji_check"
    t.check_constraint "image_content IS NULL AND image_width IS NULL AND image_height IS NULL AND image_byte_size IS NULL AND image_sha256 IS NULL OR image_content IS NOT NULL AND image_width > 0 AND image_height > 0 AND image_byte_size >= 1 AND image_byte_size <= 5000000 AND octet_length(image_content) = image_byte_size AND image_sha256::text ~ '^[0-9a-f]{64}$'::text AND SUBSTRING(image_content FROM 1 FOR 4) = '\\x52494646'::bytea AND SUBSTRING(image_content FROM 9 FOR 4) = '\\x57454250'::bytea", name: "shop_items_image_check"
    t.check_constraint "key::text ~ '^[a-z0-9_]{1,60}$'::text", name: "shop_items_key_check"
    t.check_constraint "kind::text = 'free_signup'::text AND coins = 0 OR kind::text = 'regular'::text AND coins > 0", name: "shop_items_kind_coins_check"
    t.check_constraint "kind::text = ANY (ARRAY['regular'::character varying, 'free_signup'::character varying]::text[])", name: "shop_items_kind_check"
    t.check_constraint "tier::text = ANY (ARRAY['daily'::character varying, 'weekly'::character varying, 'shop'::character varying]::text[])", name: "shop_items_tier_check"
  end

  create_table "staff_access_logs", force: :cascade do |t|
    t.bigint "actor_id"
    t.string "action", limit: 60, null: false
    t.string "subject_type", limit: 60, null: false
    t.bigint "subject_id", null: false
    t.datetime "created_at", null: false
    t.index ["actor_id"], name: "index_staff_access_logs_on_actor_id"
    t.index ["created_at"], name: "index_staff_access_logs_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_staff_access_logs_on_subject_type_and_subject_id"
  end

  create_table "team_cooldowns", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.datetime "left_at", null: false
    t.index ["user_id"], name: "index_team_cooldowns_on_user_id", unique: true
  end

  create_table "team_memberships", force: :cascade do |t|
    t.bigint "team_id", null: false
    t.bigint "user_id", null: false
    t.datetime "joined_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["team_id"], name: "index_team_memberships_on_team_id"
    t.index ["user_id"], name: "index_team_memberships_on_user_id", unique: true
  end

  create_table "team_payouts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "ship_id", null: false
    t.bigint "team_id"
    t.integer "coins", default: 0, null: false
    t.integer "matched_days", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["ship_id"], name: "index_team_payouts_on_ship_id", unique: true
    t.index ["team_id"], name: "index_team_payouts_on_team_id"
    t.index ["user_id"], name: "index_team_payouts_on_user_id"
    t.check_constraint "coins >= 0 AND matched_days >= 0", name: "team_payouts_amounts_check"
  end

  create_table "teams", force: :cascade do |t|
    t.string "name", limit: 40
    t.string "invite_token", limit: 32, null: false
    t.datetime "invite_expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invite_token"], name: "index_teams_on_invite_token", unique: true
    t.check_constraint "char_length(invite_token::text) >= 16 AND char_length(invite_token::text) <= 32", name: "teams_invite_token_check"
    t.check_constraint "name IS NULL OR char_length(name::text) >= 1 AND char_length(name::text) <= 40", name: "teams_name_check"
  end

  create_table "user_notes", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "author_id"
    t.string "body", limit: 500, null: false
    t.datetime "created_at", null: false
    t.index ["author_id"], name: "index_user_notes_on_author_id"
    t.index ["user_id", "created_at"], name: "index_user_notes_on_user_id_and_created_at"
    t.check_constraint "char_length(btrim(body::text)) >= 1", name: "user_notes_body_present_check"
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
    t.date "signed_up_on", null: false
    t.datetime "email_opted_out_at"
    t.string "email_unsubscribe_nonce", default: -> { "(gen_random_uuid())::text" }, null: false
    t.datetime "verification_checked_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["hca_uid"], name: "index_users_on_hca_uid", unique: true
    t.index ["slack_id"], name: "index_users_on_slack_id"
    t.check_constraint "char_length(project_idea) <= 500", name: "users_project_idea_length_check"
    t.check_constraint "coding_days >= 0 AND coding_days <= 127", name: "users_coding_days_check"
    t.check_constraint "coding_time IS NULL OR coding_time::text ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text", name: "users_coding_time_check"
    t.check_constraint "onboarding_step >= 0 AND onboarding_step <= 4", name: "users_onboarding_step_check"
    t.check_constraint "project_kind IS NULL OR (project_kind::text = ANY (ARRAY['game'::character varying, 'website'::character varying, 'app'::character varying, 'tool'::character varying, 'hardware'::character varying, 'undecided'::character varying]::text[]))", name: "users_project_kind_check"
    t.check_constraint "verification_status::text = ANY (ARRAY['needs_submission'::character varying, 'pending'::character varying, 'verified'::character varying, 'ineligible'::character varying]::text[])", name: "users_verification_status_check"
  end

  create_table "welcome_back_windows", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.date "starts_on", null: false
    t.date "ends_on", null: false
    t.integer "idle_days", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["starts_on"], name: "index_welcome_back_windows_on_starts_on"
    t.index ["user_id", "starts_on"], name: "index_welcome_back_windows_on_user_id_and_starts_on", unique: true
    t.check_constraint "ends_on >= starts_on", name: "welcome_back_windows_dates_check"
    t.check_constraint "idle_days >= 1", name: "welcome_back_windows_idle_days_check"
  end

  add_foreign_key "admin_audit_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "coin_transactions", "users", on_delete: :cascade
  add_foreign_key "daily_results", "users", on_delete: :cascade
  add_foreign_key "hackatime_connections", "users", on_delete: :cascade
  add_foreign_key "hackatime_day_windows", "users", on_delete: :cascade
  add_foreign_key "hackatime_links", "projects", column: ["project_id", "user_id"], primary_key: ["id", "user_id"], on_delete: :cascade
  add_foreign_key "hackatime_links", "users", on_delete: :cascade
  add_foreign_key "hour_entries", "users", on_delete: :cascade
  add_foreign_key "link_suggestions", "projects", on_delete: :cascade
  add_foreign_key "merch_claims", "bosses", on_delete: :cascade
  add_foreign_key "merch_claims", "users", on_delete: :cascade
  add_foreign_key "notification_preferences", "users", on_delete: :cascade
  add_foreign_key "notifications", "users", on_delete: :cascade
  add_foreign_key "nps_responses", "users", on_delete: :cascade
  add_foreign_key "order_events", "orders", on_delete: :cascade
  add_foreign_key "order_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "orders", "users", on_delete: :cascade
  add_foreign_key "plinko_drops", "users", on_delete: :cascade
  add_foreign_key "plinko_players", "users", on_delete: :cascade
  add_foreign_key "project_reviews", "projects", on_delete: :cascade
  add_foreign_key "project_reviews", "users", column: "reviewer_id", on_delete: :nullify
  add_foreign_key "projects", "users", on_delete: :cascade
  add_foreign_key "quest_completions", "coin_transactions", on_delete: :cascade
  add_foreign_key "quest_completions", "quests", on_delete: :cascade
  add_foreign_key "quest_completions", "users", on_delete: :cascade
  add_foreign_key "ship_images", "ships", on_delete: :cascade
  add_foreign_key "ship_images", "users", on_delete: :cascade
  add_foreign_key "ships", "projects", column: ["project_id", "user_id"], primary_key: ["id", "user_id"], on_delete: :cascade
  add_foreign_key "ships", "users", column: "reviewer_id", on_delete: :nullify
  add_foreign_key "ships", "users", on_delete: :cascade
  add_foreign_key "team_cooldowns", "users", on_delete: :cascade
  add_foreign_key "team_memberships", "teams", on_delete: :cascade
  add_foreign_key "team_memberships", "users", on_delete: :cascade
  add_foreign_key "team_payouts", "ships", on_delete: :cascade
  add_foreign_key "team_payouts", "teams", on_delete: :nullify
  add_foreign_key "team_payouts", "users", on_delete: :cascade
  add_foreign_key "user_notes", "users", column: "author_id", on_delete: :nullify
  add_foreign_key "user_notes", "users", on_delete: :cascade
  add_foreign_key "welcome_back_windows", "users", on_delete: :cascade
end
