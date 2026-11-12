module Coins
  # Approved seconds to coins, integer arithmetic only (no floats), flooring once at the very end.
  #
  # Exact unit: `units` = (full-rate seconds * 1000 + deflated seconds * multiplier_milli) * coins_per_hour.
  # There are UNITS_PER_COIN units in one coin (3600 s per hour * 1000 for the multiplier scale), so any amount of
  # units converts without rounding until `floor`.
  module Conversion
    UNITS_PER_COIN = 3_600_000

    module_function

    def units(full_seconds:, deflated_seconds: 0, config: Game::Config.current)
      (full_seconds * 1000 + deflated_seconds * config.deflation_multiplier_milli) * config.coins_per_hour
    end

    def coins_from_units(units)
      units.div(UNITS_PER_COIN)
    end

    def milli_coins_from_units(units)
      (units * 1000).div(UNITS_PER_COIN)
    end

    # Whole coins for approved seconds at the plain rate (no deflation, no bonus).
    def base_coins(approved_seconds, config: Game::Config.current)
      coins_from_units(units(full_seconds: approved_seconds, config: config))
    end

    def base_milli_coins(approved_seconds, config: Game::Config.current)
      milli_coins_from_units(units(full_seconds: approved_seconds, config: config))
    end
  end
end
