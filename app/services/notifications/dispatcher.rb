module Notifications
  # Sends the due notifications in the outbox. Safe to run from several workers at once.
  #
  # Kill switch: does nothing unless ENV["NOTIFICATIONS_ENABLED"] is exactly "true", so a deploy can never start
  # messaging people by accident. In production it also refuses to run with an adapter that does not really deliver
  # (no SLACK_BOT_TOKEN). Elsewhere such an adapter (the log adapter in development, the null adapter in tests) runs
  # the whole pipeline, but its rows are recorded as "skipped" with the code `not_delivered`, never "sent": a row is
  # only ever marked sent when a real Slack call said ok.
  #
  # How a row moves:
  # 1. Claim (short transaction): due pending rows are locked with FOR UPDATE SKIP LOCKED, so two dispatchers never
  #    get the same row. Each row is checked first (user gone / schedule changed / too late: cancelled; inside quiet
  #    hours: moved to the end of quiet hours) and a row that will be sent is leased: `attempts` goes up and `due_at`
  #    moves `lease` seconds ahead, so no one else picks it up while the HTTP call is in flight.
  # 2. Send (no lock held): the text comes from the template for the row's kind.
  # 3. Record: sent (or skipped, for an adapter that does not deliver) -> next reminder is scheduled; retryable failure -> backoff (capped, with Retry-After honoured)
  #    until max_attempts, then failed and the next reminder is scheduled; permanent failure -> failed, and no new
  #    reminder is queued (a bad Slack id would only fail again; it is re-queued when the user next calls
  #    Scheduler.schedule_next); systemic failure (bad token and so on) -> the row is released untouched and the
  #    whole run stops.
  # Event kinds (link question, ship reminders and decisions) go through the same steps, with these differences: they
  # are cancelled when the person has switched that kind off ("opted_out", checked again here so an opt-out after
  # queueing wins), when the thing they are about is gone or no longer true ("subject_gone", see Message), and when
  # they are older than `event_max_lateness` ("stale"). Every kind is checked against the preferences, the daily
  # reminder included.
  # At most one message per user is handled per run.
  #
  # One dispatcher per channel: this class handles the Slack rows (`channel: slack_dm`); Email::Dispatcher is a subclass
  # that handles the email rows through the hooks below (`channel`, `recipient_problem`, `veto`, `build_content`,
  # `deliver`), so the claim, lease, quiet hours, backoff and skipped-not-sent rules are the same for both.
  class Dispatcher
    Summary = Struct.new(:enabled, :sent, :skipped, :failed, :retried, :cancelled, :deferred, :halted, keyword_init: true)

    def self.enabled? = ENV["NOTIFICATIONS_ENABLED"] == "true"

    def self.channel = Preferences::SLACK

    def self.run(now: Time.current, limit: 100, adapter: Slack.adapter, config: Config.current)
      new(now: now, limit: limit, adapter: adapter, config: config).run
    end

    def initialize(now:, limit:, adapter:, config:)
      @now = now
      @limit = limit
      @adapter = adapter
      @config = config
      @summary = Summary.new(enabled: false, sent: 0, skipped: 0, failed: 0, retried: 0, cancelled: 0, deferred: 0, halted: false)
      @seen_user_ids = Set.new
      @reschedule = []
    end

    def run
      return @summary unless self.class.enabled?

      @summary.enabled = true
      if Rails.env.production? && !@adapter.delivers?
        Rails.logger.warn("notifications.dispatch halted reason=no_delivering_adapter channel=#{channel}")
        @summary.halted = true
        return @summary
      end

      examined = 0
      until @summary.halted || examined >= @limit
        claimed, count = claim([ @config.batch_size, @limit - examined ].min)
        break if count.zero?

        examined += count
        claimed.each_with_index do |(row, user, text), index|
          handle(row, user, text)
          next unless @summary.halted

          claimed.drop(index + 1).each { |(unsent, _user, _text)| release(unsent) }
          break
        end
        reschedule_users
      end
      Rails.logger.info("notifications.dispatch channel=#{channel} #{@summary.to_h.except(:enabled).map { |k, v| "#{k}=#{v}" }.join(' ')}")
      @summary
    end

    private

    def channel = self.class.channel

    # Hooks for a channel (Slack here). A problem with the recipient as a cancel code (nil when there is none), an extra
    # reason to drop a row (nil to go on), the content built at send time (nil: the thing it was about is gone), and the
    # send itself (a Slack::Result).
    def recipient_problem(row, user)
      "schedule_changed" unless valid_recipient?(row, user)
    end

    def veto(_row, _user) = nil

    def build_content(row, user) = Message.build(row, user, config: @config)

    def deliver(_row, user, text)
      @adapter.deliver_dm(slack_id: user.slack_id, text: text)
    rescue StandardError => e
      # Never log e.message: it could carry the recipient or text.
      Rails.logger.warn("notifications.dispatch adapter_error class=#{e.class.name}")
      Slack::Result.failure("adapter_error", retryable: true)
    end

    # Returns [[[row, user, text], ...rows to send], examined row count].
    def claim(size)
      Notification.transaction do
        rows = Notification.due(@now).where(channel: channel).where.not(user_id: @seen_user_ids.to_a).order(:due_at, :id)
                           .limit(size).lock("FOR UPDATE SKIP LOCKED").to_a
        users = User.where(id: rows.map(&:user_id)).index_by(&:id)
        claimed = rows.filter_map do |row|
          @seen_user_ids << row.user_id
          triage(row, users[row.user_id])
        end
        [ claimed, rows.size ]
      end
    end

    def triage(row, user)
      return cancel(row, "user_gone") unless user
      problem = recipient_problem(row, user)
      return cancel(row, problem, user) if problem
      return cancel(row, "opted_out", user) unless Preferences.enabled?(user, row.kind, channel: channel)
      return cancel(row, "stale", user) if @now - row.due_at > lateness_limit(row)

      reason = veto(row, user)
      return cancel(row, reason, user) if reason

      text = build_content(row, user)
      return cancel(row, "subject_gone", user) unless text

      deferral = QuietHours.deferral(@now, ActiveSupport::TimeZone[user.time_zone], config: @config)
      return defer(row, deferral) if deferral

      row.update!(attempts: row.attempts + 1, due_at: @now + @config.lease)
      [ row, user, text ]
    end

    # A daily reminder must still match the schedule it was queued for; an event only needs a recipient.
    def valid_recipient?(row, user)
      return false unless user.onboarded? && user.slack_id.present?

      daily?(row) ? Reminders.scheduled?(user, row.scheduled_for) : true
    end

    def lateness_limit(row) = daily?(row) ? @config.max_lateness : @config.event_max_lateness

    def daily?(row) = row.kind == Scheduler::KIND

    def cancel(row, code, user = nil)
      row.update!(status: "cancelled", last_error_code: code)
      @reschedule << user if user && daily?(row)
      @summary.cancelled += 1
      nil
    end

    def defer(row, until_time)
      row.update!(due_at: until_time)
      @summary.deferred += 1
      nil
    end

    def handle(row, user, text)
      result = deliver(row, user, text)
      if result.ok? && !@adapter.delivers?
        row.update!(status: "skipped", last_error_code: "not_delivered")
        @summary.skipped += 1
        @reschedule << user if daily?(row)
      elsif result.ok?
        row.update!(status: "sent", sent_at: @now, last_error_code: nil)
        @summary.sent += 1
        @reschedule << user if daily?(row)
      elsif result.systemic
        row.update!(attempts: [ row.attempts - 1, 0 ].max, due_at: @now + @config.backoff_seconds(1),
                    last_error_code: safe_code(result.error_code))
        @summary.halted = true
        Rails.logger.warn("notifications.dispatch halted reason=#{safe_code(result.error_code)}")
      elsif result.retryable && row.attempts < @config.max_attempts
        wait = [ @config.backoff_seconds(row.attempts), result.retry_after.to_i ].max
        row.update!(due_at: @now + wait, last_error_code: safe_code(result.error_code))
        @summary.retried += 1
      else
        row.update!(status: "failed", last_error_code: safe_code(result.error_code))
        @summary.failed += 1
        @reschedule << user if result.retryable && daily?(row)
        Rails.logger.info("notifications.dispatch failed notification_id=#{row.id} code=#{safe_code(result.error_code)}")
      end
    end

    def release(row)
      row.update!(attempts: [ row.attempts - 1, 0 ].max, due_at: @now)
    end

    def reschedule_users
      @reschedule.uniq(&:id).each { |user| Scheduler.schedule_next(user, now: @now) }
      @reschedule.clear
    end

    def safe_code(code)
      Notification::ERROR_CODE_FORMAT.match?(code.to_s) ? code.to_s : "unknown_error"
    end
  end
end
