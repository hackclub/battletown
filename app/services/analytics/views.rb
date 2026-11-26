require "digest"
require "erb"

module Analytics
  # The read-only `insights` schema of SQL views (db/insights/views.sql.erb, plans/analytics.md section 3). Rails does not dump views into
  # db/schema.rb, so the file is the source of truth and is applied from four places, all idempotent:
  #   - the insights migration (a database that already exists),
  #   - every load of db/schema.rb into the primary database (config/initializers/insights_views.rb: db:schema:load, db:prepare on a new
  #     database, db:test:prepare, db:setup and the per-worker test databases all end there),
  #   - `rake insights:rebuild`, and
  #   - `ensure_current!`, which rebuilds only when the SQL (or a game setting baked into it) has changed since the views were built:
  #     run by `db:prepare` on every deploy and by the test helper.
  # The checksum of the rendered SQL is kept in the comment on schema `insights`, so "are the views current" is one cheap query.
  module Views
    SOURCE = Rails.root.join("db/insights/views.sql.erb").freeze
    PUBLIC_SCHEMA = "insights".freeze
    PRIVATE_SCHEMA = "insights_private".freeze
    # Serialises concurrent rebuilds of one database (two test processes, a deploy and a rake task).
    LOCK_KEY = 4_851_620_117

    class << self
      # The SQL with the game's numbers and the measured-people rule (Exclusion.included_sql, live lists included) filled in. The lists are part of the
      # checksum, so changing them makes `ensure_current!` (every deploy's db:prepare) rebuild the views.
      def sql
        ERB.new(SOURCE.read).result_with_hash(
          days_before_signup_counted: Integer(Hours::Config.current.days_before_signup_counted),
          quick_seconds: Integer(Game::Config.current.quick_seconds),
          measured_sql: Exclusion.included_sql("users")
        )
      end

      def checksum = "sha256:#{Digest::SHA256.hexdigest(sql)}"

      # Drops both schemas and builds them again from the file, in one transaction (readers never see half a rebuild).
      def rebuild!
        ActiveRecord::Base.with_connection do |connection|
          connection.transaction do
            connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
            connection.execute("SET LOCAL client_min_messages = warning") # the DROP SCHEMA ... CASCADE notices are noise
            connection.execute(sql)
            connection.execute("COMMENT ON SCHEMA #{PUBLIC_SCHEMA} IS #{connection.quote(checksum)}")
          end
        end
        nil
      end

      # Removes both schemas (views only: no row of data is touched). For a migration that must change a column the views read.
      def drop!
        ActiveRecord::Base.with_connection do |connection|
          connection.transaction do
            connection.execute("SET LOCAL client_min_messages = warning") # the DROP SCHEMA ... CASCADE notices are noise
            connection.execute("DROP SCHEMA IF EXISTS #{PUBLIC_SCHEMA} CASCADE; DROP SCHEMA IF EXISTS #{PRIVATE_SCHEMA} CASCADE")
          end
        end
        nil
      end

      def present?
        ActiveRecord::Base.with_connection do |connection|
          connection.select_value("SELECT 1 FROM pg_namespace WHERE nspname = #{connection.quote(PUBLIC_SCHEMA)}").present?
        end
      end

      def current?
        ActiveRecord::Base.with_connection do |connection|
          connection.select_value("SELECT obj_description(oid, 'pg_namespace') FROM pg_namespace WHERE nspname = #{connection.quote(PUBLIC_SCHEMA)}") == checksum
        end
      end

      # Rebuilds when the views are missing or out of date. Returns true when it rebuilt.
      def ensure_current!
        return false if current?

        rebuild!
        true
      end

      # View names in a schema, sorted (the public contract is pinned by a test).
      def names(schema = PUBLIC_SCHEMA)
        ActiveRecord::Base.with_connection do |connection|
          connection.select_values(<<~SQL.squish)
            SELECT viewname FROM pg_views WHERE schemaname = #{connection.quote(schema)} ORDER BY viewname
          SQL
        end
      end

      # [[view, column, type], ...] for a schema: what a reader can see.
      def columns(schema = PUBLIC_SCHEMA)
        ActiveRecord::Base.with_connection do |connection|
          connection.select_rows(<<~SQL.squish)
            SELECT table_name, column_name, data_type FROM information_schema.columns
            WHERE table_schema = #{connection.quote(schema)} ORDER BY table_name, ordinal_position
          SQL
        end
      end
    end
  end
end
