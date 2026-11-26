namespace :dev do
  desc "Development only. Sample COUNT (default 24) random members of a Slack channel (DEV_SLACK_CHANNEL, default ambers-mountain) and save " \
       "their display names and pictures under tmp/dev_slack (git-ignored) for the event simulator's players. Member ids come from " \
       "tmp/dev_slack/members.json when it exists, else from Slack, which needs the bot scopes users:read (already there) and " \
       "channels:read (add it to the Slack app and reinstall; groups:read for a private channel). Run dev:slack_players_apply afterwards."
  task :slack_players, [ :count ] => :environment do |_task, args|
    abort "dev:slack_players is for development only." unless Rails.env.development?

    report = DevSimulator::SlackSample.call(count: args[:count].presence || DevSimulator::SlackSample::DEFAULT_COUNT)
    puts "dev:slack_players members=#{report.members} tried=#{report.tried} saved=#{report.written} in #{DevSimulator::SlackManifest.directory}"
  rescue DevSimulator::SlackSample::Failed, DevSimulator::Refused => error
    abort "dev:slack_players: #{error.message}"
  end

  desc "Development only. Give the simulated players that already exist the names and pictures in tmp/dev_slack (or their generated look " \
       "when the manifest is gone). Safe to run again; FORCE=1 redoes players that already look right"
  task slack_players_apply: :environment do
    abort "dev:slack_players_apply is for development only." unless Rails.env.development?

    entries = DevSimulator::SlackManifest.entries
    updated = DevSimulator::Looks.apply_all(force: ENV["FORCE"].present?)
    puts "dev:slack_players_apply manifest_entries=#{entries.size} updated=#{updated} simulated_players=#{DevSimulator.players.count}"
  rescue DevSimulator::Refused => error
    abort "dev:slack_players_apply: #{error.message}"
  end
end
