module Game
  # Settles a user's local days into immutable daily_results rows. Safe to call as often as you like (the dashboard
  # calls it lazily, `rake game:settle` calls it for everyone): it is idempotent, and serialised per user by
  # `user.with_lock` plus the unique (user_id, local_date) index.
  #
  # A local date is settled once `Days.settles_at(date, zone)` has passed, i.e. local midnight plus the grace period.
  # The first date is the local date the account was created; every later date follows the previous stored row, whose
  # streak state it continues. Late hours: an hours entry that lands on an already settled date does NOT change the
  # stored row (streaks and bonuses are final once settled), it only shows up in later live totals.
  #
  # `through:` is the instant "now" (a Time); every date settled by then is written. `source:` is any object that
  # answers `seconds_by_date(user, range) => { Date => seconds }` (see Game::HoursSource).
  module Settle
    module_function

    # Returns the DailyResult rows written by this call (empty when nothing was due).
    def call(user, through: Time.current, source: nil, config: Config.current)
      raise ArgumentError, "through: must be a Time, got #{through.class}" unless through.respond_to?(:in_time_zone) && !through.is_a?(Date)

      zone = Days.zone(user.time_zone)
      target = Days.last_settled_date(through, zone, grace_seconds: config.grace_seconds)
      # Cheap check without the lock: the dashboard calls this on every render.
      return [] if next_date(user, zone) > target

      source ||= HoursSource.current
      written = []
      user.with_lock do
        first = next_date(user, zone)
        next if first > target

        state = DailyResult.where(user_id: user.id).chronological.last&.streak_state || StreakCalculator.initial_state(config: config)
        seconds = source.seconds_by_date(user, first..target)
        (first..target).each do |date|
          result = StreakCalculator.step(state, seconds.fetch(date, 0), config: config)
          state = result.state
          written << DailyResult.create!(
            user: user, local_date: date, raw_seconds: seconds.fetch(date, 0).to_i.clamp(0..86_400),
            quick_met: result.quick_met, goal_met: result.goal_met, freeze_used: result.freeze_used,
            streak_15: state.streak_15, goal_streak: state.goal_streak, freeze_available: state.freeze_available,
            days_since_freeze: state.days_since_freeze, bonus_bps: result.bonus_bps
          )
        end
      end
      written
    end

    # The next date to settle: the day after the last stored row, or the account's creation date for a new user.
    def next_date(user, zone)
      last = DailyResult.where(user_id: user.id).maximum(:local_date)
      last ? last + 1 : Days.local_date(user.created_at, zone)
    end

    # All users, one at a time; a failure for one user is logged (no personal data) and does not stop the rest.
    def all(through: Time.current, source: nil)
      counts = { users: 0, days: 0, errors: 0 }
      User.find_each do |user|
        counts[:days] += call(user, through: through, source: source).size
        counts[:users] += 1
      rescue StandardError => error
        counts[:errors] += 1
        Rails.logger.error("game:settle failed error=#{error.class}")
      end
      counts
    end
  end
end
