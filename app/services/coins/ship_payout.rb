module Coins
  # Pure payout for one approved ship: no database, no clock, integers only.
  #
  # 1. The approved seconds are allocated to the local dates of the ship window in proportion to the seconds coded on
  #    each date, by largest remainder (ties go to the earlier date), so the allocations always sum to exactly the
  #    approved seconds.
  # 2. Deflation (coins only, never boss damage): counting chronologically, approved seconds beyond the configured
  #    threshold since the previous ship convert at the deflation multiplier. The count starts at
  #    `hours_since_previous_ship_before_window` (hours already counted toward the threshold before this window).
  # 3. Each date's base coins get that date's bonus_bps (a date missing from bonus_bps_by_date earns no bonus).
  #
  # Everything stays in exact units (see Conversion) and is floored once at the end: base_coins is the floor of the
  # whole base, total_coins the floor of base plus bonus, and bonus_coins is the difference (never negative).
  # per_date values are floored to milli-coins for display and are informational only.
  module ShipPayout
    class NothingToAllocate < ArgumentError; end

    Result = Data.define(:base_coins, :bonus_coins, :total_coins, :per_date)

    module_function

    # hours_since_previous_ship_before_window: whole or fractional hours as an Integer or Rational (Rational(seconds,
    # 3600) for an exact value). Floats are refused so no float ever enters the arithmetic.
    def call(approved_seconds:, coded_seconds_by_date:, bonus_bps_by_date: {}, hours_since_previous_ship_before_window: 0, config: Game::Config.current)
      approved = Integer(approved_seconds)
      raise ArgumentError, "approved_seconds must not be negative" if approved.negative?

      allocation = allocate(approved, coded_seconds_by_date)
      counted = threshold_offset_seconds(hours_since_previous_ship_before_window)
      base_units_total = 0
      weighted_total = 0
      per_date = {}

      allocation.sort_by { |date, _| date }.each do |date, seconds|
        full = (config.deflation_after_seconds - counted).clamp(0, seconds)
        deflated = seconds - full
        counted += seconds
        bps = Integer(bonus_bps_by_date.fetch(date, 0))
        units = Conversion.units(full_seconds: full, deflated_seconds: deflated, config: config)
        base_units_total += units
        weighted_total += units * bps
        per_date[date] = {
          allocated_seconds: seconds, full_rate_seconds: full, deflated_seconds: deflated, bonus_bps: bps,
          base_milli_coins: Conversion.milli_coins_from_units(units),
          bonus_milli_coins: Conversion.milli_coins_from_units(units * bps / 10_000)
        }
      end

      base = Conversion.coins_from_units(base_units_total)
      total = (base_units_total * 10_000 + weighted_total).div(Conversion::UNITS_PER_COIN * 10_000)
      Result.new(base_coins: base, bonus_coins: total - base, total_coins: total, per_date: per_date.freeze)
    end

    # { date => seconds } summing exactly to `approved`, proportional to the coded seconds.
    def allocate(approved, coded_seconds_by_date)
      coded = coded_seconds_by_date.to_h { |date, seconds| [ date, [ Integer(seconds), 0 ].max ] }
      return coded.transform_values { 0 } if approved.zero?

      total = coded.values.sum
      raise NothingToAllocate, "no coded seconds to allocate #{approved} approved seconds against" if total.zero?

      shares = coded.to_h { |date, seconds| [ date, approved * seconds ] }
      allocated = shares.transform_values { |share| share.div(total) }
      leftover = approved - allocated.values.sum
      shares.sort_by { |date, share| [ -(share % total), date ] }.first(leftover).each { |date, _| allocated[date] += 1 }
      allocated
    end

    def threshold_offset_seconds(hours)
      raise ArgumentError, "hours must be an Integer or Rational, not a Float" if hours.is_a?(Float)

      seconds = (Rational(hours) * 3600).floor
      raise ArgumentError, "hours_since_previous_ship_before_window must not be negative" if seconds.negative?

      seconds
    end
  end
end
