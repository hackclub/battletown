require "test_helper"

# Guards the data-deletion promise (docs/PRIVACY_API.md): Privacy::Deleter deletes the users row and relies on the
# database to cascade to everything about that person, and counts what each table lost. So a table that points at
# users must cascade, and a column that looks like it identifies a person must be covered by such a foreign key or be
# listed here, with the reason, as deliberately not personal. A new table that breaks this fails the suite until it
# is handled (add ON DELETE CASCADE, or decide what has to be retained and extend Privacy::Deleter::RETENTION_RULES).
class PrivacySchemaGuardTest < ActiveSupport::TestCase
  # Names that suggest a column holds a person's identity.
  PERSONAL_COLUMN = /user_id|slack|email|hca_uid|identity|ident_id|display_name|\bip\b|ip_address|phone|birth|address/

  # "table.column" => why it is not personal data. Nothing yet.
  NOT_PERSONAL = {}.freeze

  # Tables that are not about a person: the Rails bookkeeping tables and the token ids of this very feature.
  EXEMPT_TABLES = %w[schema_migrations ar_internal_metadata privacy_request_tokens].freeze

  def connection = ActiveRecord::Base.connection

  def app_tables = connection.tables - EXEMPT_TABLES

  def user_foreign_keys(table) = connection.foreign_keys(table).select { |fk| fk.to_table == "users" }

  test "every foreign key to users cascades on delete" do
    referencing = app_tables.flat_map { |table| user_foreign_keys(table) }
    assert_includes referencing.map(&:from_table), "notifications", "the guard found no foreign keys at all"

    referencing.each do |fk|
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
      cascading = user_foreign_keys(table).select { |fk| fk.on_delete == :cascade }.map(&:column)
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
    user = users(:onboarded)
    Notification.create!(user: user, kind: "daily_reminder", status: "sent", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "guard-#{user.id}")
    HourEntry.create!(user: user, local_date: Date.new(2026, 11, 10), seconds: 600, source: "manual", note: "guard", idempotency_key: "guard-#{user.id}")
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: user.hca_uid)

    deleted = Privacy::Deleter.new(subject).call(dry_run: true).deleted

    referencing = app_tables.select { |table| user_foreign_keys(table).any? }
    assert_equal (referencing + [ "users" ]).sort, deleted.keys.sort,
                 "add a row for the new table to this test so its count is proven (every table that references users must show up)"
  end
end
