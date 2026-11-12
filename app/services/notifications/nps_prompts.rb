module Notifications
  # Periodic scan (`bin/rails notifications:nps_prompts`, a few times a day from cron) that queues the NPS survey DM
  # (kind `nps_prompt`) for everyone Nps::Eligibility says is due. Behind the Flipper flag `nps`: with the flag off it
  # reads nothing, queues nothing and reports zero.
  #
  # One message per person per prompt window (their local date): the idempotency key is `nps_prompt:<user id>:<window
  # date>` and the eligibility rules keep windows at least `nps.interval_days` apart, so a repeated or concurrent scan can
  # never send two. "No Slack id", "not onboarded" and the person's own switch are handled by Outbox (a nil result);
  # quiet hours and the kill switch by the dispatcher. A failure on one person never stops the others.
  module NpsPrompts
    Result = Data.define(:scanned, :queued)

    module_function

    def scan(now: Time.current, config: Nps::Config.current)
      return Result.new(scanned: 0, queued: 0) unless Features.enabled?(:nps)

      scanned = 0
      queued = 0
      candidates(now, config).find_each do |user|
        scanned += 1
        queued += 1 if queue(user, now, config)
      rescue StandardError => e
        Rails.logger.warn("notifications.nps_prompts error=#{e.class.name}")
      end
      Rails.logger.info("notifications.nps_prompts scanned=#{scanned} queued=#{queued}")
      Result.new(scanned: scanned, queued: queued)
    end

    # Onboarded users with a Slack id who have any ledger row in the window (a wide UTC range: local dates differ from UTC
    # by up to a day either way); Eligibility does the exact, per-time-zone check.
    def candidates(now, config)
      from = now.utc.to_date - config.active_days - 1
      User.where.not(onboarded_at: nil).where.not(slack_id: [ nil, "" ])
          .where(id: HourEntry.where(local_date: from..(now.utc.to_date + 1)).select(:user_id))
    end

    # True when a new row was queued.
    def queue(user, now, config)
      verdict = Nps::Eligibility.check(user, now: now, config: config)
      return false unless verdict.eligible?

      date = verdict.window_date
      row = Outbox.enqueue(user: user, kind: "nps_prompt", subject_id: Nps::Eligibility.subject_id(date),
                           key: Nps::Eligibility.key(user, date), now: now)
      row.present? && row.previously_new_record?
    end
  end
end
