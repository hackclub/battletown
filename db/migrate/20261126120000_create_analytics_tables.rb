# First-party analytics (projects/battletown/plans/analytics.md, section 1.2): one row per browser visit (a random token, never an IP or a
# user agent), one row per allowlisted event (jsonb props, at most 400 bytes) and one row per person per day they used the site.
# Every table that points at a person cascades from users, so Privacy::Deleter removes it all (and the pre-sign-up trail too, because
# a visit is stamped with its user at sign-in). Nothing here is ever pruned: no TTL, no retention job (the owner wants to look back at all of
# it), so the rows are narrow and only the indexes a query needs exist. Also adds the two users columns the metrics need: `analytics_excluded` (staff, simulated
# players and listed testers are never measured) and `analytics_id`, the random id the insights views show instead of users.id.
class CreateAnalyticsTables < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_visits do |t|
      t.string :visit_key, limit: 32, null: false
      t.references :user, foreign_key: { on_delete: :cascade }
      t.datetime :started_at, null: false
      t.string :referral_slug, limit: 32
      t.string :utm_source, limit: 32
      t.string :utm_medium, limit: 32
      t.string :utm_campaign, limit: 40
      t.string :referrer_kind, limit: 12, null: false, default: "direct"
      t.string :device_class, limit: 10, null: false, default: "unknown"
      t.string :entry_route, limit: 80
    end
    add_index :analytics_visits, :visit_key, unique: true
    add_index :analytics_visits, :started_at
    add_check_constraint :analytics_visits, "referrer_kind IN ('direct', 'search', 'social', 'hack_club', 'other')", name: "analytics_visits_referrer_kind_check"
    add_check_constraint :analytics_visits, "device_class IN ('desktop', 'mobile', 'tablet', 'unknown')", name: "analytics_visits_device_class_check"

    create_table :analytics_events do |t|
      t.string :name, limit: 40, null: false
      t.jsonb :props, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.references :visit, foreign_key: { to_table: :analytics_visits, on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :cascade }, index: false # (user_id, occurred_at) below already serves the cascade
      t.string :dedupe_key, limit: 60
    end
    add_index :analytics_events, %i[name occurred_at]
    add_index :analytics_events, :occurred_at, using: :brin # append-only and in time order: a range over every event (the hourly snapshot, the admin page) at almost no index size
    add_index :analytics_events, %i[user_id occurred_at]
    add_index :analytics_events, %i[user_id dedupe_key], unique: true, where: "dedupe_key IS NOT NULL"
    add_check_constraint :analytics_events, "jsonb_typeof(props) = 'object'", name: "analytics_events_props_object_check"
    add_check_constraint :analytics_events, "octet_length(props::text) <= 400", name: "analytics_events_props_size_check"
    add_check_constraint :analytics_events, "name ~ '^[a-z][a-z0-9_]*$'", name: "analytics_events_name_check"

    create_table :analytics_site_days do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :day, null: false
    end
    add_index :analytics_site_days, %i[user_id day], unique: true
    add_index :analytics_site_days, :day

    add_column :users, :analytics_excluded, :boolean, null: false, default: false
    add_column :users, :analytics_id, :uuid, null: false, default: -> { "gen_random_uuid()" }
    add_index :users, :analytics_id, unique: true
  end
end
