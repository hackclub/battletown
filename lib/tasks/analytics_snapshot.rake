# The daily aggregate snapshots (app/services/analytics/snapshot.rb). Run hourly from cron: it upserts today's row per key, and the first run after
# midnight finishes yesterday's flows (the last run of a day stops at :45). Prints counts only. See analytics.rake for the other operator tools; nothing here deletes anything.
namespace :analytics do
  desc "Store today's aggregates in analytics_daily_snapshots (one number per key per day, no people; safe to repeat). Run hourly from cron"
  task snapshot: :environment do
    JobRun.record("analytics:snapshot") do |counts|
      result = Analytics::Snapshot.call
      finished = Analytics::Snapshot.finalize_previous_day
      counts.merge!(keys: result.keys, finalized: finished ? 1 : 0)
      puts "analytics:snapshot day=#{result.day.iso8601} keys=#{result.keys}#{" finalized=#{finished.day.iso8601}" if finished}"
    end
  end
end
