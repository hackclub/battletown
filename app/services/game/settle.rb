module Game
  # Settles a user's local days into immutable daily_results rows. Safe to call as often as you like (the dashboard
  # calls it lazily, `rake game:settle` calls it for everyone): it is idempotent, and serialised per user by
  # `user.with_lock` plus the unique (user_id, local_date) index.
  #
  # A local date is settled once `Days.settles_at(date, zone)` has passed, i.e. local midnight plus the grace period.
  # The first date is the user's first counted date (`Hours::Days.first_counted_date`: the local date the account was
  # created, by default; hours before it count for nothing); every later date follows the previous stored row, whose
  # streak state it continues. Late hours: an hours entry that lands on an already settled date does NOT change the
  # stored row (streaks and bonuses are final once settled), it only shows up in later live totals.
  #
  # Returning-user bonus (feature flag `returning`, Game::ReturningBoost): while the flag is on, the day's stored
  # `bonus_bps` is raised to the welcome-back floor on a qualifying day inside a window (and the window is opened,
  # idempotently, on the first qualifying day back after an idle stretch). The streak state is never touched; with the
  # flag off this step does nothing and no window is written.
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
      return [] if next_date(user) > target

      source ||= HoursSource.current
      written = []
      user.with_lock do
        first = next_date(user)
        next if first > target

        state = DailyResult.where(user_id: user.id).chronological.last&.streak_state || StreakCalculator.initial_state(config: config)
        seconds = source.seconds_by_date(user, first..target)
        returning = ReturningBoost::Tracker.new(user, before: first) if Features.enabled?(:returning)
        (first..target).each do |date|
          result = StreakCalculator.step(state, seconds.fetch(date, 0), config: config)
          state = result.state
          bonus_bps = returning ? returning.bonus_for(date, result) : result.bonus_bps
          written << DailyResult.create!(
            user: user, local_date: date, raw_seconds: seconds.fetch(date, 0).to_i.clamp(0..86_400),
            quick_met: result.quick_met, goal_met: result.goal_met, freeze_used: result.freeze_used,
            streak_15: state.streak_15, goal_streak: state.goal_streak, freeze_available: state.freeze_available,
            days_since_freeze: state.days_since_freeze, bonus_bps: bonus_bps
          )
        end
      end
      written
    end

    # The next date to settle: the day after the last stored row, or the first counted date for a new user.
    def next_date(user)
      last = DailyResult.where(user_id: user.id).maximum(:local_date)
      last ? last + 1 : Hours::Days.first_counted_date(user)
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
