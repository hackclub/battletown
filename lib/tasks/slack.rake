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
end
