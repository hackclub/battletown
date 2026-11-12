module Notifications
  # Periodic scan (`bin/rails notifications:returning_nudges`, daily or so from cron, after `game:settle`) that queues the
  # returning-user nudge: ONE Slack DM per idle period to someone who has gone quiet (feature flag `returning`).
  #
  # Idle is counted like the bonus counts it (Game::ReturningBoost): settled local days since the person's last
  # qualifying 15-minute day. A person is nudged when that reaches `returning.idle_days`, and not once it passes
  # `returning.nudge_max_idle_days` (nobody who left long ago is messaged, and a nudge row pruned by
  # notifications:prune can never be sent again). Only someone with at least one qualifying day ever, who finished
  # onboarding and has a Slack id, who is not already back today, and who still has welcome-back windows left. A deleted
  # account has no rows, so nothing is ever queued for it.
  #
  # Idempotent: the key is `returning_nudge:<user id>:<last qualifying date>`, so the same idle period never queues a
  # second message however often this runs; coming back and going quiet again is a new idle period and a new key. The
  # kill switch, quiet hours and the per-kind switch are the outbox's and the dispatcher's (see Outbox, Dispatcher).
  # With the flag off nothing is read and nothing is queued. A failure for one person never stops the others.
  module ReturningNudges
    KIND = "returning_nudge".freeze

    Result = Data.define(:scanned, :queued)

    module_function

    def scan(now: Time.current)
      return Result.new(scanned: 0, queued: 0) unless Features.enabled?(:returning)

      scanned = 0
      queued = 0
      candidates(now).find_each do |user|
        scanned += 1
        queued += 1 if check(user, now)
      rescue StandardError => e
        Rails.logger.warn("notifications.returning_nudges error=#{e.class.name}")
      end
      Rails.logger.info("notifications.returning_nudges scanned=#{scanned} queued=#{queued}")
      Result.new(scanned: scanned, queued: queued)
    end

    # Onboarded users with a Slack id whose last settled qualifying day is far enough back (UTC dates, one day of slack
    # for time zones: the exact test is `check`) and not so far back that they are beyond a nudge, plus anyone whose days
    # have not been settled lately (`game:settle` normally keeps everyone current; `check` settles them first, so a missed
    # run never hides someone who went quiet).
    def candidates(now)
      config = Game::ReturningBoost.config
      today = now.utc.to_date
      base = User.where.not(onboarded_at: nil).where.not(slack_id: [ nil, "" ])
      last_active = DailyResult.where(quick_met: true).group(:user_id)
                               .having("MAX(local_date) BETWEEN ? AND ?", today - config.nudge_max_idle_days - 2, today - config.idle_days)
      fresh = DailyResult.where(local_date: (today - 2)..).select(:user_id)
      base.where(id: last_active.select(:user_id)).or(base.where.not(id: fresh))
    end

    # True when a new outbox row was queued.
    def check(user, now)
      config = Game::ReturningBoost.config
      Game::Settle.call(user, through: now)
      last_on = last_active_on(user)
      return false unless last_on

      idle = (Game::Days.last_settled_date(now, user.time_zone) - last_on).to_i
      return false unless idle.between?(config.idle_days, config.nudge_max_idle_days)
      return false if WelcomeBackWindow.where(user_id: user.id).count >= config.max_windows
      return false if back_today?(user, now)

      row = Outbox.enqueue(user: user, kind: KIND, subject_id: subject_for(last_on), key: key(user, last_on), now: now)
      row.present? && row.previously_new_record?
    end

    def key(user, last_on) = "#{KIND}:#{user.id}:#{last_on.iso8601}"

    # The person's last settled qualifying day (nil when there is none).
    def last_active_on(user) = DailyResult.where(user_id: user.id, quick_met: true).maximum(:local_date)

    # The row's `subject_id`: the last active day as days since 1970-01-01, so the dispatcher can tell the nudge is still true.
    def subject_for(date) = (date - Date.new(1970, 1, 1)).to_i

    # Today (their own local date) already has 15 minutes: they are back, no nudge.
    def back_today?(user, now)
      Hours::Totals.seconds_for_date(user, Hours::Days.today(user, now: now)) >= Game::Config.current.quick_seconds
    end
  end
end
