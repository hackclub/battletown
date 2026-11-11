# Registry of everything Battletown stores about a person. It drives the self-service export
# (AccountExport) and is checked against the real schema by test/models/account_data_test.rb.
#
# Adding a table that belongs to a user (a project, a log, a notification, ...):
#   1. Give it a `user_id` foreign key with `on_delete: :cascade`, so deleting the user row removes it
#      (AccountDeletion only deletes the user row and relies on the database for the rest).
#   2. Add one Source below. The test fails until you do both.
module AccountData
  # key:         the name of the section in the export file
  # table:       the database table
  # model_name:  the ActiveRecord model (a String, so this file survives code reloading)
  # user_column: the column that points at the user ("id" for the users table itself)
  # except:      columns left out of the export (internal ids only; the person gets everything else)
  # decorate:    optional lambda(row_hash, record) to add readable fields
  Source = Struct.new(:key, :table, :model_name, :user_column, :except, :decorate, keyword_init: true) do
    def model = model_name.constantize

    def records_for(user) = model.where(user_column => user.id)
  end

  # Never exported even if a column of this name is added later: these claims are not stored at all.
  NEVER_EXPORT = %w[phone birthdate address].freeze

  SOURCES = [
    Source.new(
      key: "profile", table: "users", model_name: "User", user_column: "id",
      # `id` is internal; `hca_uid` is kept because it is their Hack Club Auth identifier.
      except: %w[id],
      decorate: ->(row, record) { row.merge("coding_day_names" => record.coding_day_names) }
    ),
    # The outbox of Slack reminders (kind, status, times, attempts). It stores no message text and no Slack id.
    Source.new(
      key: "notifications", table: "notifications", model_name: "Notification", user_column: "user_id",
      except: %w[id user_id]
    )
  ].freeze

  IGNORED_TABLES = %w[schema_migrations ar_internal_metadata].freeze

  def self.sources = SOURCES

  # Human-readable problems with how the registry and the schema line up. Empty means consistent.
  def self.problems(connection: ActiveRecord::Base.connection, sources: SOURCES)
    problems = []
    registered = sources.map(&:table)
    (connection.tables - IGNORED_TABLES).sort.each do |table|
      user_fks = connection.foreign_keys(table).select { |fk| fk.to_table == "users" }
      user_fks.each do |fk|
        problems << "#{table}.#{fk.column} references users without on_delete: :cascade" unless fk.on_delete == :cascade
      end
      if user_fks.empty? && table != "users" && connection.columns(table).any? { |c| c.name == "user_id" }
        problems << "#{table}.user_id has no foreign key to users"
      end
      if (user_fks.any? || table == "users") && !registered.include?(table)
        problems << "#{table} references users but is not in AccountData::SOURCES"
      end
    end
    (registered - connection.tables).each { |table| problems << "AccountData::SOURCES lists #{table}, which does not exist" }
    problems
  end
end
