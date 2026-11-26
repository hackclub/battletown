# The `insights` views are plain SQL (db/insights/views.sql.erb); Analytics::Views builds them. Nothing here deletes a row of data.
namespace :insights do
  desc "Rebuild the insights views from db/insights/views.sql.erb (safe to repeat; run after changing the file or hours.days_before_signup_counted / streaks.quick_minutes)."
  task rebuild: :environment do
    Analytics::Views.rebuild!
    puts "insights:rebuild views=#{Analytics::Views.names.size}"
  end

  desc "Create the NOLOGIN role insights_reader if it is missing and re-apply its read-only grants on the insights views. Give it a login by hand: ALTER ROLE insights_reader LOGIN PASSWORD '...'."
  task reader_role: :environment do
    ActiveRecord::Base.with_connection do |connection|
      connection.execute("DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'insights_reader') THEN CREATE ROLE insights_reader NOLOGIN; END IF; END $$")
    end
    Analytics::Views.rebuild!
    puts "insights:reader_role insights_reader may read #{Analytics::Views.names.size} views in schema insights"
  end
end

# Every deploy runs db:prepare (bin/docker-entrypoint): rebuild the views there when the file, or a game setting baked into it, has changed.
Rake::Task["db:prepare"].enhance do
  puts "insights views rebuilt" if Analytics::Views.ensure_current!
end
