require "test_helper"
require_relative "../support/every_table_rows"

# Guards the data-deletion promise (docs/PRIVACY_API.md): Privacy::Deleter deletes the users row and relies on the
# database to cascade to everything about that person, and counts what each table lost. So a table that points at
# users must cascade, and a column that looks like it identifies a person must be covered by such a foreign key or be
# listed here, with the reason, as deliberately not personal. A new table that breaks this fails the suite until it
# is handled (add ON DELETE CASCADE, or decide what has to be retained and extend Privacy::Deleter::RETENTION_RULES).
class PrivacySchemaGuardTest < ActiveSupport::TestCase
  include EveryTableRows

  # Names that suggest a column holds a person's identity.
  PERSONAL_COLUMN = /user_id|slack|email|hca_uid|identity|ident_id|display_name|\bip\b|ip_address|phone|birth|address/

  # "table.column" => why the guard's name match is not a gap. These ARE personal (a shipping address is), but encrypted at rest, and
  # the whole row goes with the person: order_addresses.user_id and address_offers.user_id cascade (the first test above).
  NOT_PERSONAL = {
    "order_addresses.phone_number" => "encrypted; the row cascades from users (order_addresses.user_id) and from the order",
    "order_addresses.hca_address_id" => "an opaque Hack Club Auth address id, not an address; the row cascades from users"
  }.freeze

  # Foreign keys to users that deliberately do NOT cascade, with the reason: the row is about someone else (the subject
  # of the row is reached through a cascading key), and the key is nulled so the staff member is forgotten.
  NULLIFY_ALLOWED = {
    "ships.reviewer_id" => "the staff member who reviewed a ship; the ship belongs to the teen",
    "admin_audit_events.actor_id" => "the staff member who did it; the trail holds ids and amounts, never another person's identity",
    "project_reviews.reviewer_id" => "the staff member who reviewed a project; the review belongs to the project (and so to the teen)",
    "order_events.actor_id" => "the person who changed the order (a staff member, or the buyer); the history row belongs to the order, which cascades",
    "user_notes.author_id" => "the staff member who wrote a private note; the note belongs to the person it is about (a cascading key)"
  }.freeze

  # Tables that are not about a person: the Rails bookkeeping tables and the token ids of this very feature.
  EXEMPT_TABLES = %w[schema_migrations ar_internal_metadata privacy_request_tokens].freeze

  def connection = ActiveRecord::Base.connection

  def app_tables = connection.tables - EXEMPT_TABLES

  def user_foreign_keys(table) = connection.foreign_keys(table).select { |fk| fk.to_table == "users" }

  test "every foreign key to users cascades on delete" do
    referencing = app_tables.flat_map { |table| user_foreign_keys(table) }
    assert_includes referencing.map(&:from_table), "notifications", "the guard found no foreign keys at all"

    referencing.each do |fk|
      if NULLIFY_ALLOWED.key?("#{fk.from_table}.#{fk.column}")
        assert_equal :nullify, fk.on_delete, "#{fk.from_table}.#{fk.column} is listed as nulled on delete"
        next
      end

      assert_equal :cascade, fk.on_delete, "#{fk.from_table}.#{fk.column} references users without ON DELETE CASCADE: a person's data would survive (or block) deletion"
    end
  end

  test "tables that reference a table owned by a user cascade too" do
    owned = app_tables.select { |table| user_foreign_keys(table).any? { |fk| fk.on_delete == :cascade } }
    assert_includes owned, "notifications"
    app_tables.flat_map { |table| connection.foreign_keys(table) }.select { |fk| owned.include?(fk.to_table) }.each do |fk|
      assert_equal :cascade, fk.on_delete, "#{fk.from_table}.#{fk.column} references #{fk.to_table} (owned by a user) without ON DELETE CASCADE"
    end
  end

  test "columns that look personal are covered by a cascading foreign key or listed as not personal" do
    offenders = (app_tables - [ "users" ]).flat_map do |table|
      cascading = user_foreign_keys(table).select { |fk| fk.on_delete == :cascade || NULLIFY_ALLOWED.key?("#{fk.from_table}.#{fk.column}") }.map(&:column)
      connection.columns(table).map(&:name).select { |name| name.match?(PERSONAL_COLUMN) }
                .reject { |name| cascading.include?(name) || NOT_PERSONAL.key?("#{table}.#{name}") }.map { |name| "#{table}.#{name}" }
    end

    assert_empty offenders, "These look like personal data but are not a cascading foreign key to users. Make them one, or add them " \
                            "to NOT_PERSONAL with the reason (and handle them in Privacy::Deleter if they must go)"
  end

  test "the users table has the identifiers the subject finder matches on" do
    assert_equal %w[email hca_uid slack_id], (User.column_names & %w[email hca_uid slack_id]).sort
  end

  test "every table referencing users is counted when a user is deleted" do
    user = user_with_rows_in_every_table
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: user.hca_uid)

    deleted = Privacy::Deleter.new(subject).call(dry_run: true).deleted

    # Tables that reference users directly, plus the ones that only reach a user through a project.
    # (A table whose only key to users is a nulling one, the staff access log, loses no rows when a person is deleted.)
    referencing = app_tables.select { |table| user_foreign_keys(table).any? { |fk| fk.on_delete == :cascade } }
    through_projects = %w[link_suggestions project_reviews] # a crew with no members left is swept by Privacy::Deleter
    through_orders = %w[order_events] # the history of an order goes with the order (ON DELETE CASCADE); order_addresses also has its own user_id key
    swept = %w[teams]
    through_subject = %w[admin_audit_events] # no foreign key: Privacy::Deleter removes the audit rows whose subject is the person
    assert_equal (referencing + through_projects + through_orders + swept + through_subject + [ "users" ]).sort, deleted.keys.sort,
                 "add a row for the new table to this test so its count is proven (every table that references users must show up)"
  end
end
