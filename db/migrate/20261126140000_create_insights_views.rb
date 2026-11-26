# The read-only `insights` views (db/insights/views.sql.erb, plans/analytics.md section 3). They are SQL, so db/schema.rb does not hold them: a new
# database gets them from the hook in config/initializers/insights_views.rb after the schema loads, and this migration builds them on a database
# that already exists. Nothing is stored and nothing is deleted: dropping the views does not touch a row.
#
# A later (or earlier) migration that changes a column the views read needs no care: config/initializers/insights_views.rb drops the views before
# every other migration and rebuilds them after it.
class CreateInsightsViews < ActiveRecord::Migration[8.1]
  def up
    # The one event the views look up per person (the first Hackatime link): a partial index holds one row per linked person, so it stays one probe
    # however many events the table collects. Every other lookup uses an index that already exists.
    add_index :analytics_events, %i[user_id occurred_at], where: "name = 'hackatime_linked'", name: "index_analytics_events_hackatime_linked"
    Analytics::Views.rebuild!
  end

  def down
    Analytics::Views.drop!
    remove_index :analytics_events, name: "index_analytics_events_hackatime_linked"
  end
end
