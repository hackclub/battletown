# Operator tools for first-party analytics (config/analytics.yml, app/services/analytics/**). They print counts only. There is deliberately no
# task that deletes analytics data on a schedule: nothing is pruned (test/services/analytics/no_retention_test.rb guards that).
namespace :analytics do
  desc "Apply ADMIN_HCA_UIDS, ANALYTICS_EXCLUDE_HCA_UIDS and the sim! players to users.analytics_excluded and delete what was recorded about them. " \
       "Run once after deploying and whenever the lists change (a person is also refreshed at their next sign-in)."
  task refresh_exclusions: :environment do
    counts = Analytics::Exclusion.refresh_all!
    puts "analytics:refresh_exclusions excluded=#{counts[:excluded]} newly_marked=#{counts[:marked]} cleared=#{counts[:cleared]}"
  end
end
