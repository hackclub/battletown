# Loaded by `db:prepare` only when the cache database is a separate, not yet existing database
# (CACHE_DATABASE_URL). With the default single-database layout the same table comes from
# db/cache_migrate. Keep the version equal to the newest file in db/cache_migrate.
ActiveRecord::Schema[8.1].define(version: 2026_11_11_210000) do
  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", limit: 4, null: false
    t.datetime "created_at", null: false
    t.binary "key", limit: 1024, null: false
    t.integer "key_hash", limit: 8, null: false
    t.binary "value", limit: 536870912, null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end
end
