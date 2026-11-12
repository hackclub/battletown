# The order lifecycle: six statuses (requested, on_hold, shipped, fulfilled, cancelled, refunded), tracking on the order and
# an append-only history table. Existing rows keep their status (requested, fulfilled and cancelled are all still valid), so
# nothing is rewritten. Everything is written out literally so this migration keeps working if the model constants change.
#
# `orders`: shipped_at and refunded_at join fulfilled_at and cancelled_at. A fulfilled order may be refunded later (a lost
# or wrong item), so fulfilled_at is kept on a refunded order. Tracking is three small columns (the carrier from a short
# allowlist, the number, and a label when the carrier is "other"); a number only exists with a carrier and a shipped_at.
#
# `order_events`: one row per status change, tracking edit or staff note. The order is its owner (ON DELETE CASCADE, so
# deleting a person deletes the history); the actor is a kind (buyer, staff or system) plus, for staff only, an id (nulled when
# that staff member is deleted; the buyer is the order's owner already). No names, no Slack ids, no addresses. The note is a short staff-written line; it is never copied into the audit trail.
class AddOrderLifecycle < ActiveRecord::Migration[8.1]
  OLD_STATUSES = %w[requested fulfilled cancelled].freeze
  STATUSES = %w[requested on_hold shipped fulfilled cancelled refunded].freeze
  ACTIONS = %w[held released shipped fulfilled cancelled refunded tracking_updated note_added].freeze
  ACTOR_KINDS = %w[buyer staff system].freeze
  ORDER_CHECKS = %w[orders_refunded_at_check orders_shipped_at_check orders_shipped_at_status_check orders_tracking_pair_check
                    orders_tracking_carrier_check orders_tracking_number_check orders_tracking_label_check].freeze

  def up
    add_column :orders, :shipped_at, :datetime
    add_column :orders, :refunded_at, :datetime
    add_column :orders, :tracking_carrier, :string, limit: 20
    add_column :orders, :tracking_number, :string, limit: 60
    add_column :orders, :tracking_label, :string, limit: 40

    replace_order_checks(STATUSES)
    add_check_constraint :orders, "(status = 'refunded') = (refunded_at IS NOT NULL)", name: "orders_refunded_at_check"
    add_check_constraint :orders, "status <> 'shipped' OR shipped_at IS NOT NULL", name: "orders_shipped_at_check"
    add_check_constraint :orders, "shipped_at IS NULL OR status IN ('shipped', 'fulfilled', 'refunded')", name: "orders_shipped_at_status_check"
    add_check_constraint :orders, "(tracking_carrier IS NULL) = (tracking_number IS NULL)", name: "orders_tracking_pair_check"
    add_check_constraint :orders, "tracking_carrier IS NULL OR tracking_carrier ~ '^[a-z_]{2,20}$'", name: "orders_tracking_carrier_check"
    add_check_constraint :orders, "tracking_number IS NULL OR (tracking_number ~ '^[A-Za-z0-9][A-Za-z0-9 -]{2,59}$' AND shipped_at IS NOT NULL)", name: "orders_tracking_number_check"
    add_check_constraint :orders, "tracking_label IS NULL OR (tracking_carrier = 'other' AND char_length(tracking_label) BETWEEN 1 AND 40 AND tracking_label !~ '[[:cntrl:]]')", name: "orders_tracking_label_check"

    create_table :order_events do |t|
      t.references :order, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :actor, index: false, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :actor_kind, null: false, limit: 10
      t.string :action, null: false, limit: 20
      t.string :from_status, limit: 20
      t.string :to_status, limit: 20
      t.string :reason_code, limit: 30
      t.string :note, limit: 300
      t.datetime :created_at, null: false
    end
    add_index :order_events, %i[order_id created_at]
    add_index :order_events, :actor_id, where: "actor_id IS NOT NULL"
    add_check_constraint :order_events, "actor_kind IN (#{quoted(ACTOR_KINDS)})", name: "order_events_actor_kind_check"
    add_check_constraint :order_events, "action IN (#{quoted(ACTIONS)})", name: "order_events_action_check"
    add_check_constraint :order_events, "from_status IS NULL OR from_status IN (#{quoted(STATUSES)})", name: "order_events_from_status_check"
    add_check_constraint :order_events, "to_status IS NULL OR to_status IN (#{quoted(STATUSES)})", name: "order_events_to_status_check"
    add_check_constraint :order_events, "reason_code IS NULL OR reason_code ~ '^[a-z_]{2,30}$'", name: "order_events_reason_code_check"
    add_check_constraint :order_events, "note IS NULL OR (char_length(note) BETWEEN 1 AND 300 AND note !~ '[[:cntrl:]]')", name: "order_events_note_check"
    add_check_constraint :order_events, "actor_kind = 'staff' OR actor_id IS NULL", name: "order_events_actor_check"
  end

  def down
    drop_table :order_events

    # A new status has no old equivalent: an order that was held or shipped goes back to requested, a refunded one to cancelled.
    remove_check_constraint :orders, name: "orders_status_check"
    remove_check_constraint :orders, name: "orders_fulfilled_at_check"
    ORDER_CHECKS.each { |name| remove_check_constraint :orders, name: name }
    execute "UPDATE orders SET status = 'requested', shipped_at = NULL, tracking_carrier = NULL, tracking_number = NULL, tracking_label = NULL WHERE status IN ('on_hold', 'shipped')"
    execute "UPDATE orders SET status = 'cancelled', cancelled_at = refunded_at, fulfilled_at = NULL WHERE status = 'refunded'"
    execute "UPDATE orders SET tracking_carrier = NULL, tracking_number = NULL, tracking_label = NULL"
    remove_column :orders, :shipped_at
    remove_column :orders, :refunded_at
    remove_column :orders, :tracking_carrier
    remove_column :orders, :tracking_number
    remove_column :orders, :tracking_label
    add_check_constraint :orders, "status IN (#{quoted(OLD_STATUSES)})", name: "orders_status_check"
    add_check_constraint :orders, "(status = 'fulfilled') = (fulfilled_at IS NOT NULL)", name: "orders_fulfilled_at_check"
  end

  private

  # The status list and the fulfilled_at rule: fulfilled_at is set when fulfilled, kept when a fulfilled order is refunded,
  # and absent in every other status.
  def replace_order_checks(statuses)
    remove_check_constraint :orders, name: "orders_status_check"
    remove_check_constraint :orders, name: "orders_fulfilled_at_check"
    add_check_constraint :orders, "status IN (#{quoted(statuses)})", name: "orders_status_check"
    add_check_constraint :orders, "(status <> 'fulfilled' OR fulfilled_at IS NOT NULL) AND (fulfilled_at IS NULL OR status IN ('fulfilled', 'refunded'))", name: "orders_fulfilled_at_check"
  end

  def quoted(values) = values.map { |value| "'#{value}'" }.join(", ")
end
