module Dashboard
  # The streak picture the dashboard needs, worked out from the user's settled days (daily_results) plus the days that
  # have closed but are not settled yet (the grace period, or a settle that failed) plus today so far.
  #
  # Settled days are never recomputed: the last stored row carries the streak state forward. Any later closed days are
  # folded through the pure Game::StreakCalculator from the live hours ledger, one date range query in all. Today is
  # NOT folded (it is not over): it only adds one to a streak if it has already reached the mark.
  #
  # The live day ("today so far") is today, or the day after the last settled one when that is later: after a move west
  # by more than the grace period, the new zone's today can be a date that has already settled. That date is final (its
  # row already counts it) and new hours land on the next date, so the next date is the live one.
  #
  # Reads only the given user's own rows. Returns a Snapshot of plain values.
  class Streaks
    Snapshot = Data.define(:today_seconds, :carried_quick, :carried_goal, :quick_today_met, :goal_today_met,
                           :best_quick, :best_goal, :freeze_ready, :freeze_used_on, :last_day_frozen) do
      # Streak day counts as they stand now: today counts once it has reached its mark.
      def quick_days = carried_quick + (quick_today_met ? 1 : 0)

      def goal_days = carried_goal + (goal_today_met ? 1 : 0)
    end

    def self.call(user:, today:, config: Game::Config.current) = new(user: user, today: today, config: config).call

    def initialize(user:, today:, config:)
      @user = user
      @today = today
      @config = config
    end

    def call
      rows = DailyResult.where(user_id: @user.id)
      last = rows.chronological.last
      best_quick, best_goal, freeze_on = rows.pick(Arel.sql("MAX(streak_15)"), Arel.sql("MAX(goal_streak)"),
                                                   Arel.sql("MAX(local_date) FILTER (WHERE freeze_used)"))
      state = last&.streak_state || Game::StreakCalculator.initial_state(config: @config)
      first = last ? last.local_date + 1 : Hours::Days.first_counted_date(@user)
      live = [ @today, (last.local_date + 1 if last) ].compact.max
      seconds = Hours::Totals.seconds_by_date(@user, [ first, live ].min..live)
      last_frozen = !last.nil? && last.local_date == live - 1 && last.freeze_used

      (first...live).each do |date|
        result = Game::StreakCalculator.step(state, seconds.fetch(date, 0), config: @config)
        state = result.state
        best_quick = [ best_quick.to_i, state.streak_15 ].max
        best_goal = [ best_goal.to_i, state.goal_streak ].max
        freeze_on = date if result.freeze_used
        last_frozen = result.freeze_used
      end

      today_seconds = seconds.fetch(live, 0)
      snapshot = Snapshot.new(today_seconds: today_seconds, carried_quick: state.streak_15, carried_goal: state.goal_streak,
                              quick_today_met: today_seconds >= @config.quick_seconds, goal_today_met: today_seconds >= @config.goal_seconds,
                              best_quick: best_quick.to_i, best_goal: best_goal.to_i, freeze_ready: state.freeze_available,
                              freeze_used_on: freeze_on, last_day_frozen: last_frozen)
      snapshot.with(best_quick: [ snapshot.best_quick, snapshot.quick_days ].max, best_goal: [ snapshot.best_goal, snapshot.goal_days ].max)
    end
  end
end
