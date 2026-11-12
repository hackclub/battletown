module Game
  # The streak bonus ramp: the bonus, in basis points, a qualifying day earns by its 15-minute streak day.
  # Day 1 is the first qualifying day after a reset. Pure: reads only the table it is given.
  module BonusRamp
    module_function

    # 0 for a day below 1 (no streak), the last table entry for any day past the end of the table.
    def bps(streak_day, config: Config.current)
      day = Integer(streak_day)
      return 0 if day < 1

      config.ramp_bps.fetch([ day, config.ramp_bps.size ].min - 1)
    end
  end
end
