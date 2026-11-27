namespace :team do
  desc "Pay the crew bonus for recently approved ships whose payout did not run (needs the `team` flag). Safe to repeat; run every 15 minutes or so from cron."
  task pay_pending: :environment do
    result = Teams::PayPending.scan
    puts "team:pay_pending enabled=#{Features.enabled?(:team)} scanned=#{result.scanned} paid=#{result.paid}"
  end
end
