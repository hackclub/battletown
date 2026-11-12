module Game
  # The streak rules as one pure transition per settled local day.
  #
  # 15-minute streak (`streak_15`): a day counts at >= quick_seconds. It drives the bonus ramp. A missed day resets it
  # to 0 unless the single freeze is available and there is a streak to protect: then the day is "frozen" (the streak
  # is kept, it does not increment, no bonus). The freeze is re-earned after `freeze_regen_days` consecutive qualifying
  # days since it was used (cap 1).
  #
  # Daily-goal streak (`goal_streak`): a day counts at >= goal_seconds. Only a counter (for a later weekly merch
  # track): no bonus, no freeze, a miss resets it.
  module StreakCalculator
    State = Data.define(:streak_15, :goal_streak, :freeze_available, :days_since_freeze)
    Day = Data.define(:raw_seconds)
    Result = Data.define(:state, :quick_met, :goal_met, :freeze_used, :bonus_bps)

    module_function

    def initial_state(config: Config.current)
      State.new(streak_15: 0, goal_streak: 0, freeze_available: config.freeze_starts_available, days_since_freeze: 0)
    end

    # `day` is a Day or the day's raw coded seconds (negative or nil count as 0).
    def step(state, day, config: Config.current)
      raw = (day.is_a?(Day) ? day.raw_seconds : day).to_i.clamp(0..)
      quick_met = raw >= config.quick_seconds
      goal_met = raw >= config.goal_seconds
      goal_streak = goal_met ? state.goal_streak + 1 : 0

      if quick_met
        streak = state.streak_15 + 1
        available, since = regenerate(state, config)
        next_state = State.new(streak_15: streak, goal_streak: goal_streak, freeze_available: available, days_since_freeze: since)
        Result.new(state: next_state, quick_met: true, goal_met: goal_met, freeze_used: false, bonus_bps: BonusRamp.bps(streak, config: config))
      elsif state.streak_15.positive? && state.freeze_available
        next_state = State.new(streak_15: state.streak_15, goal_streak: goal_streak, freeze_available: false, days_since_freeze: 0)
        Result.new(state: next_state, quick_met: false, goal_met: goal_met, freeze_used: true, bonus_bps: 0)
      else
        next_state = State.new(streak_15: 0, goal_streak: goal_streak, freeze_available: state.freeze_available, days_since_freeze: 0)
        Result.new(state: next_state, quick_met: false, goal_met: goal_met, freeze_used: false, bonus_bps: 0)
      end
    end

    # Folds `step` over days in date order (each a Day or raw seconds) and returns one Result per day.
    def replay(days, state: nil, config: Config.current)
      state ||= initial_state(config: config)
      days.map do |day|
        result = step(state, day, config: config)
        state = result.state
        result
      end
    end

    # A qualifying day while the freeze is spent counts toward re-earning it.
    def regenerate(state, config)
      return [ true, 0 ] if state.freeze_available

      since = state.days_since_freeze + 1
      since >= config.freeze_regen_days ? [ true, 0 ] : [ false, since ]
    end
    private_class_method :regenerate
  end
end
