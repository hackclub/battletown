namespace :notifications do
  desc "Send due notifications (needs NOTIFICATIONS_ENABLED=true). Run every minute or so from cron."
  task dispatch: :environment do
    JobRun.record("notifications:dispatch") do |run|
      summary = Notifications::Dispatcher.run
      puts "notifications:dispatch enabled=#{summary.enabled} sent=#{summary.sent} skipped=#{summary.skipped} failed=#{summary.failed} " \
           "retried=#{summary.retried} cancelled=#{summary.cancelled} deferred=#{summary.deferred} halted=#{summary.halted}"
      # The email rows, by the same rules; does nothing while the Flipper flag `email` is off or without a real SMTP transport in production.
      email = Notifications::Email::Dispatcher.run
      puts "notifications:dispatch channel=email enabled=#{email.enabled} sent=#{email.sent} skipped=#{email.skipped} failed=#{email.failed} " \
           "retried=#{email.retried} cancelled=#{email.cancelled} deferred=#{email.deferred} halted=#{email.halted}"
      { slack: summary, email: email }.each do |channel, counts|
        %i[enabled sent skipped failed retried cancelled deferred halted].each { |field| run["#{channel}_#{field}"] = counts.public_send(field) }
      end
    end
  end

  desc "Queue ship reminders for projects whose unshipped hours crossed a threshold (ships.reminder_hours in config/game.yml). Run every 15 minutes or so from cron; safe to repeat."
  task ship_reminders: :environment do
    JobRun.record("notifications:ship_reminders") do |run|
      result = Notifications::ShipReminders.scan
      run.merge!(scanned: result.scanned, queued: result.queued)
      puts "notifications:ship_reminders scanned=#{result.scanned} queued=#{result.queued}"
    end
  end

  desc "Queue the NPS survey DM for everyone due one (flag `nps`; nothing happens while it is off). Run a few times a day from cron; safe to repeat."
  task nps_prompts: :environment do
    JobRun.record("notifications:nps_prompts") do |run|
      result = Notifications::NpsPrompts.scan
      run.merge!(scanned: result.scanned, queued: result.queued)
      puts "notifications:nps_prompts scanned=#{result.scanned} queued=#{result.queued}"
    end
  end

  desc "Queue the returning-user nudge for people idle for returning.idle_days (config/game.yml; needs the `returning` flag). Run daily from cron after game:settle; safe to repeat."
  task returning_nudges: :environment do
    JobRun.record("notifications:returning_nudges") do |run|
      result = Notifications::ReturningNudges.scan
      run.merge!(scanned: result.scanned, queued: result.queued)
      puts "notifications:returning_nudges scanned=#{result.scanned} queued=#{result.queued}"
    end
  end

  desc "Queue the next daily reminder for every onboarded user with a Slack id (safe to repeat)"
  task schedule_all: :environment do
    JobRun.record("notifications:schedule_all") do |run|
      count = 0
      User.where.not(onboarded_at: nil).where.not(slack_id: [ nil, "" ]).find_each do |user|
        count += 1 if Notifications::Scheduler.schedule_next(user)
      end
      run[:scheduled] = count
      puts "notifications:schedule_all scheduled=#{count}"
    end
  end

  desc "Delete finished notifications older than retention_days (config/notifications.yml)"
  task prune: :environment do
    JobRun.record("notifications:prune") do |run|
      run[:deleted] = Notifications::Retention.prune
      puts "notifications:prune deleted=#{run[:deleted]}"
    end
  end
end

namespace :nps do
  desc "Empty NPS comments older than nps.comment_retention_days (config/game.yml); scores are kept. Run daily from cron."
  task prune: :environment do
    JobRun.record("nps:prune") do |run|
      run[:emptied] = Nps::Prune.call
      puts "nps:prune emptied=#{run[:emptied]}"
    end
  end
end
