require "test_helper"
require "open3"

# db/schema.rb cannot hold the insights views, so every way of building a database has to end with them (config/initializers/insights_views.rb,
# the migration, `db:prepare`). This drives the real rake tasks against a scratch database, the way CI (db:test:prepare) and a deploy
# (db:prepare) do, and checks the views are there each time, never touching the database the suite runs in.
class InsightsSchemaLoadTest < ActiveSupport::TestCase
  PUBLIC_VIEW_COUNT = 15

  setup do
    @suffix = "_insights_probe_#{Process.pid}"
    # A DATABASE_URL naming a database would make the child process work on the suite's own database: never run then.
    url = ENV["DATABASE_URL"].to_s
    skip "DATABASE_URL names a database, so a scratch database cannot be chosen" if url.present? && URI.parse(url).path.to_s.delete("/").present?
    # What the child process will name its database: config/database.yml's test database with TEST_DB_SUFFIX replaced (a parallel worker's own
    # database name carries a worker number, so it is not the base to start from).
    base = ActiveRecord::Base.connection_db_config.database.sub(/#{Regexp.escape(ENV['TEST_DB_SUFFIX'].to_s)}(_\d+)?\z/, "")
    @database = "#{base}#{@suffix}"
    assert_not_equal ActiveRecord::Base.connection_db_config.database, @database
  end

  teardown { rake("db:drop") if @database && @created }

  def rake(*tasks)
    env = { "RAILS_ENV" => "test", "TEST_DB_SUFFIX" => @suffix, "DISABLE_DATABASE_ENVIRONMENT_CHECK" => "1" }
    output, status = Open3.capture2e(env, "bin/rails", *tasks, chdir: Rails.root.to_s)
    assert_predicate status, :success?, "bin/rails #{tasks.join(' ')} failed:\n#{output}"
    output
  end

  def probe(sql)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    connection = PG.connect({ host: config[:host], port: config[:port], user: config[:username], password: config[:password], dbname: @database }.compact)
    connection.exec(sql).values
  ensure
    connection&.close
  end

  def view_count = probe("SELECT COUNT(*) FROM pg_views WHERE schemaname = 'insights'").first.first.to_i

  test "db:prepare on a new database, db:schema:load, db:test:prepare and a later db:prepare all leave the views in place" do
    rake("db:prepare")
    @created = true
    assert_equal PUBLIC_VIEW_COUNT, view_count, "db:prepare on a new database"
    assert_equal [ [ "0" ] ], probe("SELECT COUNT(*) FROM insights.funnel_facts")

    probe("DROP SCHEMA insights CASCADE; DROP SCHEMA insights_private CASCADE")
    assert_equal 0, view_count
    rake("db:schema:load")
    assert_equal PUBLIC_VIEW_COUNT, view_count, "db:schema:load"

    probe("DROP SCHEMA insights CASCADE; DROP SCHEMA insights_private CASCADE")
    rake("db:test:prepare")
    assert_equal PUBLIC_VIEW_COUNT, view_count, "db:test:prepare"

    # An existing database with nothing pending (every deploy): db:prepare rebuilds views whose file or game settings changed since.
    probe("COMMENT ON SCHEMA insights IS 'sha256:stale'")
    assert_match(/insights views rebuilt/, rake("db:prepare"))
    assert_equal Analytics::Views.checksum, probe("SELECT obj_description('insights'::regnamespace, 'pg_namespace')").first.first
  end
end
