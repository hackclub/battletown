# Shipping addresses for physical orders (docs/CONTRACT.md, "Shipping addresses").
#
# order_addresses: the ONE address chosen for an order, copied from Hack Club Auth when the order is placed. Every personal
# column is ciphertext (Active Record encryption), hence `text`; only the country (an ISO 3166-1 alpha-2 code, for staff
# planning), the Hack Club Auth address id (traceability) and the purge date are plaintext. It belongs to the order AND to
# the person (both keys cascade), so deleting either takes it with it.
#
# address_offers: the list Hack Club Auth returned at checkout, kept encrypted for a few minutes so the person can choose,
# then cleared. One per person and checkout (draft key).
#
# order_events gets three history entries (no content, ever). The allowlist is the full current list plus the new ones.
class CreateAddressTables < ActiveRecord::Migration[8.1]
  OLD_ACTIONS = %w[held released shipped fulfilled cancelled refunded tracking_updated note_added].freeze
  NEW_ACTIONS = %w[address_changed address_revealed address_purged].freeze

  def up
    create_table :order_addresses do |t|
      t.references :order, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, index: true, foreign_key: { on_delete: :cascade }
      t.text :recipient_name, null: false
      t.text :line_1, null: false
      t.text :line_2
      t.text :city, null: false
      t.text :state
      t.text :postal_code
      t.text :phone_number
      t.string :country, limit: 2, null: false
      t.string :hca_address_id, limit: 80
      t.datetime :purge_after
      t.timestamps
    end
    add_index :order_addresses, :purge_after, where: "purge_after IS NOT NULL"
    add_check_constraint :order_addresses, "country ~ '^[A-Z]{2}$'", name: "order_addresses_country_check"
    add_check_constraint :order_addresses, "hca_address_id IS NULL OR char_length(hca_address_id) BETWEEN 1 AND 80", name: "order_addresses_hca_address_id_check"

    create_table :address_offers do |t|
      t.references :user, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :draft_key, limit: 100, null: false
      t.text :payload, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end
    add_index :address_offers, %i[user_id draft_key], unique: true
    add_index :address_offers, :expires_at
    add_check_constraint :address_offers, "char_length(draft_key) BETWEEN 1 AND 100", name: "address_offers_draft_key_check"

    replace_action_check(OLD_ACTIONS + NEW_ACTIONS)
  end

  def down
    execute "DELETE FROM order_events WHERE action IN (#{NEW_ACTIONS.map { |action| "'#{action}'" }.join(', ')})"
    replace_action_check(OLD_ACTIONS)
    drop_table :address_offers
    drop_table :order_addresses
  end

  private

  def replace_action_check(actions)
    remove_check_constraint :order_events, name: "order_events_action_check"
    add_check_constraint :order_events, "action IN (#{actions.map { |action| "'#{action}'" }.join(', ')})", name: "order_events_action_check"
  end
end
