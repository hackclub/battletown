# Solid Cable's messages table (production only; see config/cable.yml and config/database.yml). Same shape as the schema the solid_cable
# install generator ships. It lives in its own migration path so the primary schema (db/schema.rb, used by development and test) stays free
# of cable tables. Rows are short-lived: Solid Cable trims what is older than the retention in config/cable.yml.
class CreateSolidCableMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :solid_cable_messages do |t|
      t.binary :channel, limit: 1024, null: false
      t.binary :payload, limit: 536870912, null: false
      t.datetime :created_at, null: false
      t.integer :channel_hash, limit: 8, null: false

      t.index :channel_hash
      t.index :created_at
    end
  end
end
