namespace :notifications do
  desc "Send due notifications (needs NOTIFICATIONS_ENABLED=true). Run every minute or so from cron."
  task dispatch: :environment do
    summary = Notifications::Dispatcher.run
    puts "notifications:dispatch enabled=#{summary.enabled} sent=#{summary.sent} failed=#{summary.failed} " \
         "retried=#{summary.retried} cancelled=#{summary.cancelled} deferred=#{summary.deferred} halted=#{summary.halted}"
  end

  desc "Queue ship reminders for projects whose unshipped hours crossed a threshold (ships.reminder_hours in config/game.yml). Run every 15 minutes or so from cron; safe to repeat."
  task ship_reminders: :environment do
    result = Notifications::ShipReminders.scan
    puts "notifications:ship_reminders scanned=#{result.scanned} queued=#{result.queued}"
  end

  desc "Queue the next daily reminder for every onboarded user with a Slack id (safe to repeat)"
  task schedule_all: :environment do
    count = 0
    User.where.not(onboarded_at: nil).where.not(slack_id: [ nil, "" ]).find_each do |user|
      count += 1 if Notifications::Scheduler.schedule_next(user)
    end
    puts "notifications:schedule_all scheduled=#{count}"
  end

  desc "Delete finished notifications older than retention_days (config/notifications.yml)"
  task prune: :environment do
    puts "notifications:prune deleted=#{Notifications::Retention.prune}"
  end
end
