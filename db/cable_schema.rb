# Loaded by `db:prepare` only when the cable database is a separate, not yet existing database (CABLE_DATABASE_URL). With the default
# single-database layout the same table comes from db/cable_migrate. Keep the version equal to the newest file in db/cable_migrate.
ActiveRecord::Schema[8.1].define(version: 2026_11_26_220000) do
  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", limit: 1024, null: false
    t.integer "channel_hash", limit: 8, null: false
    t.datetime "created_at", null: false
    t.binary "payload", limit: 536870912, null: false
    t.index [ "channel_hash" ], name: "index_solid_cable_messages_on_channel_hash"
    t.index [ "created_at" ], name: "index_solid_cable_messages_on_created_at"
  end
end
