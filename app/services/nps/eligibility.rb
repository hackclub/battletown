module Nps
  # Who gets the survey DM, and for which prompt window. Pure reads; nothing is written here.
  #
  # A person is asked (at most once per `nps.interval_days`) when ALL of these hold, in their own time zone:
  # - they finished onboarding and have a Slack id (Notifications::Outbox also checks their switch for this kind);
  # - they are ACTIVE: at least `nps.active_minutes` of counted coded time on at least one of the last `nps.active_days`
  #   local days (today included);
  # - they did not answer within the last `nps.cooldown_days_after_answer` days;
  # - they were not asked within the last `nps.interval_days` days;
  # - they have not ignored `nps.max_prompts_without_answer` prompts in a row. The run restarts when they answer, and
  #   when they come back after an idle stretch: a gap of more than `nps.idle_days_reset` days between two active days.
  # "Asked" means a prompt that is pending, sent or skipped (a cancelled or failed one never reached them).
  #
  # The prompt window is the person's local date. It is part of the idempotency key, so a repeated scan in one window
  # never queues a second message.
  module Eligibility
    ASKED_STATUSES = %w[pending sent skipped].freeze
    Result = Data.define(:eligible, :reason, :window_date) do
      def eligible? = eligible
    end

    module_function

    def check(user, now: Time.current, config: Config.current)
      return refuse(:not_reachable) unless user.onboarded? && user.slack_id.present?

      today = Hours::Days.today(user, now: now)
      active = active_dates(user, (today - (config.active_days - 1))..today, config)
      return refuse(:not_active) if active.empty?

      last_answer = NpsResponse.where(user_id: user.id).maximum(:answered_at)
      answered_on = last_answer && Hours::Days.local_date(last_answer, user)
      return refuse(:cooldown) if answered_on && answered_on + config.cooldown_days > today

      asked = Notification.where(user_id: user.id, kind: "nps_prompt", status: ASKED_STATUSES).pluck(:scheduled_for)
                          .map { |time| Hours::Days.local_date(time, user) }
      return refuse(:recently_asked) if asked.any? { |date| date + config.interval_days > today }
      return refuse(:too_many_unanswered) if unanswered_in_a_row(user, asked, answered_on, today, config) >= config.max_unanswered

      Result.new(eligible: true, reason: nil, window_date: today)
    end

    # Subject id and idempotency key for the prompt window `date`.
    def subject_id(date) = date.strftime("%Y%m%d").to_i

    def window_date(subject_id)
      Date.strptime(subject_id.to_s, "%Y%m%d")
    rescue ArgumentError, TypeError
      nil
    end

    def key(user, date) = "nps_prompt:#{user.id}:#{date.iso8601}"

    # Local dates in `range` on which the person counted at least `nps.active_minutes`.
    def active_dates(user, range, config)
      Hours::Totals.seconds_by_date(user, range).select { |_date, seconds| seconds >= config.active_seconds }.keys.sort
    end

    # Prompts since their last answer and since they last came back from an idle stretch.
    def unanswered_in_a_row(user, asked, answered_on, today, config)
      since = asked.select { |date| answered_on.nil? || date > answered_on }
      return 0 if since.empty?

      days = active_dates(user, (since.min)..today, config)
      restart = days.each_cons(2).select { |before, after| (after - before) > config.idle_days_reset }.map(&:last).max
      restart ? since.count { |date| date >= restart } : since.size
    end

    def refuse(reason) = Result.new(eligible: false, reason: reason, window_date: nil)
  end
end
