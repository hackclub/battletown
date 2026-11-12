# The local date each account was created on, stored once so the sign-up cutoff (Hours::Days.first_counted_date) no
# longer moves when the user changes time zone. Existing rows are backfilled from created_at in their current zone, in
# batches outside one long transaction; NOT NULL goes on through a validated check constraint so the table is never
# locked for a full scan.
class AddSignedUpOnToUsers < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BATCH = 5_000
  CHECK = "users_signed_up_on_null".freeze

  def up
    add_column :users, :signed_up_on, :date, if_not_exists: true
    nil until backfill_batch.zero?
    # Rows created (by the old code) after the last batch are caught here; the constraint refuses any later NULL.
    add_check_constraint :users, "signed_up_on IS NOT NULL", name: CHECK, validate: false
    nil until backfill_batch.zero?
    validate_check_constraint :users, name: CHECK
    change_column_null :users, :signed_up_on, false
    remove_check_constraint :users, name: CHECK
  end

  def down
    remove_column :users, :signed_up_on
  end

  private

  # The local date of created_at (UTC) in the user's zone: users.time_zone holds a Rails zone name (or an IANA id),
  # mapped to the IANA id PostgreSQL knows; a blank or unknown zone is UTC, as in Ruby.
  def backfill_batch
    exec_update(<<~SQL.squish)
      UPDATE users
      SET signed_up_on = ((users.created_at AT TIME ZONE 'UTC') AT TIME ZONE COALESCE(batch.iana, 'UTC'))::date
      FROM (
        SELECT pending.id, zones.iana
        FROM users AS pending
        LEFT JOIN (VALUES #{zone_values}) AS zones(name, iana) ON zones.name = pending.time_zone
        WHERE pending.signed_up_on IS NULL
        ORDER BY pending.id
        LIMIT #{BATCH}
      ) AS batch
      WHERE users.id = batch.id
    SQL
  end

  def zone_values
    @zone_values ||= begin
      known = select_values("SELECT name FROM pg_timezone_names").to_set
      rows = ActiveSupport::TimeZone.all.flat_map { |zone| [ [ zone.name, zone.tzinfo.name ], [ zone.tzinfo.name, zone.tzinfo.name ] ] }
                                    .uniq(&:first).select { |_, iana| known.include?(iana) }
      rows.map { |name, iana| "(#{quote(name)}, #{quote(iana)})" }.join(", ")
    end
  end
end
