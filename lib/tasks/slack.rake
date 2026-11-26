namespace :slack do
  desc "Check SLACK_BOT_TOKEN with Slack's auth.test: prints the workspace, bot name and scopes, never the token"
  task check: :environment do
    report = Notifications::Slack::Check.new.call
    if report.team
      scopes = report.scopes ? report.scopes.join(",") : "unknown (Slack sent no x-oauth-scopes header)"
      puts "slack:check workspace=#{report.team.inspect} bot=#{report.user.inspect} scopes=#{scopes}"
    end
    if report.ok?
      puts "slack:check ok"
    else
      report.problems.each { |problem| warn "slack:check problem: #{problem}" }
      exit 1
    end
  end

  desc "Send ONE test DM to the Slack user id you give: bin/rails \"slack:self_test[U...]\" (needs SLACK_BOT_TOKEN)"
  task :self_test, [ :slack_id ] => :environment do |_task, args|
    slack_id = args[:slack_id].to_s.strip
    unless slack_id.match?(/\A[UW][A-Z0-9]{2,20}\z/)
      abort "slack:self_test needs a Slack user id, for example: bin/rails \"slack:self_test[U0123456789]\""
    end
    abort "slack:self_test: SLACK_BOT_TOKEN is not set, nothing was sent." if ENV["SLACK_BOT_TOKEN"].blank?

    text = "Test message from Battletown (slack:self_test). Nothing to do. - the Hack Club Battletown team"
    result = Notifications::Slack::WebApiAdapter.new.deliver_dm(slack_id: slack_id, text: text)
    abort "slack:self_test failed: #{result.error_code}" unless result.ok?

    puts "slack:self_test sent 1 message"
  end

  desc "Fetch the Slack name and picture of players that are due (at most LIMIT, default 100, one at a time under Slack's limit)"
  task refresh_profiles: :environment do
    abort "slack:refresh_profiles: SLACK_BOT_TOKEN is not set, nothing was fetched." unless SlackProfiles.token?

    limit = ENV.fetch("LIMIT", "100").to_i.clamp(1, 1000)
    counts = Hash.new(0)
    SlackProfiles.due_scope.limit(limit).each do |user|
      outcome = SlackProfiles::Refresh.call(user)
      counts[outcome.status] += 1
      if outcome.status == :waiting || outcome.status == :ratelimited
        warn "slack:refresh_profiles: Slack asked us to slow down; stopping, run it again later"
        break
      end
      break if %i[missing_scope invalid_auth no_token].include?(outcome.status)

      sleep 0.7 # about 85 a minute at most; Gate also holds the shared limit
    end
    puts "slack:refresh_profiles #{counts.map { |status, count| "#{status}=#{count}" }.join(' ').presence || 'nothing due'}"
  end

  desc "Counts of the Slack profile fetches by status (counts only, no names): bin/rails slack:profile_status"
  task profile_status: :environment do
    puts "slack:profile_status token=#{SlackProfiles.token? ? 'set' : 'missing'} with_slack_id=#{User.where.not(slack_id: [ nil, '' ]).count} " \
         "due=#{SlackProfiles.due_scope.count} #{SlackProfile.group(:status).count.sort.map { |status, count| "#{status}=#{count}" }.join(' ')}"
  end
end
