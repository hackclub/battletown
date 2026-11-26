# db/schema.rb cannot hold the `insights` views (Rails does not dump views, and `db:migrate` would erase anything added by hand), so every load
# of the schema into the primary database builds them straight afterwards. All the ways of loading it go through
# ActiveRecord::Tasks::DatabaseTasks.load_schema: db:schema:load, db:setup, db:reset, db:prepare on a new database, db:test:prepare, the test
# helper's maintain_test_schema! and the per-worker databases of a parallel test run. Analytics::Views carries the file and its checksum;
# test/db/insights_views_test.rb loads the schema into a scratch database to prove it.
module InsightsViewsAfterSchemaLoad
  def load_schema(db_config, *)
    result = super
    Analytics::Views.rebuild! if db_config.name == "primary" && db_config.schema_format.to_sym == :ruby
    result
  end
end

ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(InsightsViewsAfterSchemaLoad)

# The views read most of the tables (users, projects, ships, orders, order_events, hour_entries, notifications ...), and Postgres refuses to drop or
# retype anything a view reads ("other objects depend on it"). So every migration drops the views first and builds them again afterwards (in the
# migration's own transaction, so a failed migration leaves them as they were), and no migration, old or future, has to know about them. The insights
# migration itself is left alone: it builds them. When a down migration removed a table the views read, they are left out (with a message) until the
# next `db:prepare` or `rake insights:rebuild`. Only views are touched; no row of data is.
module InsightsViewsAroundMigrations
  def migrate(direction)
    return super if self.class.name == "CreateInsightsViews" || !Analytics::Views.present?

    Analytics::Views.drop!
    result = super
    rebuild_insights_views
    result
  end

  private

  # Inside a savepoint, so a rebuild that cannot work (a table the views read is gone) does not abort the migration's transaction.
  def rebuild_insights_views
    ActiveRecord::Base.transaction(requires_new: true) { Analytics::Views.rebuild! }
  rescue ActiveRecord::StatementInvalid => error
    say "insights views not rebuilt (#{error.class}); run `bin/rails insights:rebuild` once the tables they read exist"
  end
end

ActiveRecord::Migration.prepend(InsightsViewsAroundMigrations)
