module Notifications
  # Periodic scan (`bin/rails notifications:ship_reminders`, every 15 minutes or so) that queues the ship nudges.
  #
  # For each live project with a linked Hackatime project, belonging to an onboarded user with a Slack id, it reads the
  # hours coded since the project's last counted ship (`Ships::Window`) and finds the highest threshold in
  # `ships.reminder_hours` (config/game.yml) that the hours have reached: the first is a `ship_reminder`, the second a
  # `ship_mvp`. Only that one is queued, so someone who was away and crossed both gets one message, not two (a pending
  # lower one is cancelled). One message per project per threshold per ship window: the idempotency key is
  # `<kind>:<project id>:<window start>:<threshold hours>`, where the window start is the day after the previous counted
  # ship's last day (`first` when there is none). A new ship starts a new window, so the next one can nudge again.
  #
  # Per-person switches and "no Slack id" are handled by Outbox (a null result, never an error); quiet hours by the
  # dispatcher. Safe to run any number of times, and a failure on one project never stops the others.
  module ShipReminders
    KINDS = %w[ship_reminder ship_mvp].freeze # in threshold order

    Result = Data.define(:scanned, :queued)

    module_function

    def thresholds = Ships::Config.current.reminder_seconds

    # The seconds of coded time at which `kind` fires.
    def threshold_seconds(kind) = thresholds.fetch(KINDS.index(kind.to_s))

    def scan(now: Time.current)
      scanned = 0
      queued = 0
      candidates.find_each do |project|
        scanned += 1
        queued += 1 if check(project, now)
      rescue StandardError => e
        Rails.logger.warn("notifications.ship_reminders error=#{e.class.name}")
      end
      Rails.logger.info("notifications.ship_reminders scanned=#{scanned} queued=#{queued}")
      Result.new(scanned: scanned, queued: queued)
    end

    # Owners and links are preloaded per batch: Ships::Window and Outbox read both for every project.
    def candidates
      Project.live.joins(:user).merge(User.where.not(onboarded_at: nil).where.not(slack_id: [ nil, "" ]))
             .where(id: HackatimeLink.select(:project_id)).includes(:user, :hackatime_links)
    end

    # Queues the reminder for the highest threshold the project's window has reached. True when a new row was made.
    def check(project, now)
      coded = Ships::Window.call(project).seconds
      index = thresholds.rindex { |seconds| coded >= seconds }
      return false unless index

      kind = KINDS.fetch(index)
      lower = KINDS.first(index)
      row = Outbox.enqueue(user: project.user, kind: kind, subject_id: project.id, key: key(project, kind, thresholds.fetch(index)), now: now)
      return false unless row

      cancel_lower(project, lower, now)
      row.previously_new_record?
    end

    def key(project, kind, threshold)
      last_end = project.ships.where(status: Ship::WINDOW_STATUSES).maximum(:window_end_date)
      start = last_end ? (last_end + 1).iso8601 : "first"
      "#{kind}:#{project.id}:#{start}:#{Message.hours_text(threshold)}"
    end

    def cancel_lower(project, kinds, now)
      return if kinds.empty?

      Notification.pending.where(user_id: project.user_id, subject_id: project.id, kind: kinds).update_all(status: "cancelled", updated_at: now)
    end

    # A submitted ship ends the nudging for its project: pending reminders are no longer true.
    def cancel_pending_for(project_id, now: Time.current)
      Notification.pending.where(kind: KINDS, subject_id: project_id).update_all(status: "cancelled", updated_at: now)
    end
  end
end
