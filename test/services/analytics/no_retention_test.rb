require "test_helper"

# The owner's rule: retain all analytics data. Nothing prunes, expires or partitions it away; the only deletions are the cascade when a person
# (or Hack Club) asks for their data to be deleted, and an operator acting by hand (plus the exclusion purge of staff and test players).
class AnalyticsNoRetentionTest < ActiveSupport::TestCase
  ROOT = Rails.root
  TABLES = /AnalyticsVisit|AnalyticsEvent|AnalyticsSiteDay|AnalyticsDailySnapshot|JobRun|analytics_visits|analytics_events|analytics_site_days|analytics_daily_snapshots|job_runs/
  DELETING = /delete_all|destroy_all|\.delete\(|\.destroy\b|DELETE\s+FROM|TRUNCATE|DROP\s+TABLE|drop_partition|DETACH\s+PARTITION|expires_in|\.where\([^)]*(<|older|ago)/i
  # The only places allowed to delete analytics rows: the exclusion purge (staff, simulated and listed test players), documented in its header.
  ALLOWED = %w[app/services/analytics/exclusion.rb].freeze

  def files(*globs) = globs.flat_map { |glob| Dir[ROOT.join(glob)] }.select { |path| File.file?(path) }

  # A file's code and settings without its comment lines (the comments are where the "never pruned" promise is written down).
  def code_of(path) = File.read(path).lines.reject { |line| line.lstrip.start_with?("#") }.join

  test "there is no analytics prune, retention, expiry or cleanup task" do
    tasks = files("lib/tasks/**/*.rake").flat_map { |path| File.read(path).scan(/^\s*(?:namespace|task)\s+:?"?(\w+)/).flatten }
    assert_includes tasks, "analytics", "the guard found no analytics tasks at all"
    offenders = files("lib/tasks/**/*.rake").select do |path|
      code_of(path).match?(/analytics[^\n]*(prune|retention|retain|ttl|expire|cleanup|clean_up|purge_old|delete_old)|(prune|retention|expire|cleanup)[^\n]*analytics/i)
    end
    assert_empty offenders.map { |path| Pathname(path).relative_path_from(ROOT).to_s }
  end

  test "no code or config deletes, expires or ages out analytics rows, apart from the exclusion purge" do
    offenders = files("app/**/*.rb", "lib/**/*.{rb,rake}", "config/**/*.{rb,yml}", "db/migrate/*.rb").flat_map do |path|
      relative = Pathname(path).relative_path_from(ROOT).to_s
      next [] if ALLOWED.include?(relative) || relative.start_with?("config/environments/", "db/migrate/2026010", "db/migrate/20250")

      File.readlines(path).each_with_index.filter_map { |line, index| "#{relative}:#{index + 1}" if line.match?(TABLES) && line.match?(DELETING) && !line.lstrip.start_with?("#") }
    end
    assert_empty offenders, "analytics data is retained indefinitely: nothing may delete it on a schedule (see plans/analytics.md, Retention)"
  end

  test "there is no retention setting, cron entry or partition job for analytics" do
    config = files("config/analytics.yml", "config/recurring.yml", ".env.example").map { |path| code_of(path) }.join("\n")
    assert_no_match(/retention|retain|prune|ttl|expire|partition/i, config)
    # config/job_schedule.yml does list the prune tasks of OTHER tables (notifications, nps, ship screenshots); no analytics task may be among them.
    scheduled = YAML.safe_load_file(ROOT.join("config/job_schedule.yml")).fetch("jobs").keys
    assert_equal [ "analytics:snapshot" ], scheduled.grep(/analytics/)
    assert_no_match(/ANALYTICS_RETENTION|ANALYTICS_TTL|ANALYTICS_PRUNE/, files("{app,lib,config,db,test}/**/*.{rb,rake,yml,erb}").reject { |path| path.end_with?("no_retention_test.rb") }.map { |path| File.read(path) }.join("\n"))
  end

  test "the tables the migrations create have no partition or expiry clause" do
    migrations = files("db/migrate/*analytics*.rb", "db/migrate/*job_runs*.rb").map { |path| code_of(path) }.join("\n")
    assert_no_match(/partition|expire|ttl/i, migrations)
  end
end
