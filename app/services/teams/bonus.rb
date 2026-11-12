module Teams
  # The pure maths of the crew bonus: no database, no clock, no flag, integers only.
  #
  # A date earns the bonus for the earner when at least ONE OTHER crewmate coded at least `threshold` seconds on that local
  # date (Hours::Totals rules: counted hours only, so dates before that crewmate signed up never match) AND both people had
  # been in the crew for the whole date: a person is "in for" a date when they joined at or before the start of that date in
  # their own time zone (joining at 15:00 on the 10th counts from the 11th). Each person uses their own local date, so a
  # crew spread over time zones is approximate (a crewmate's 23:30 can fall on a different calendar day for the earner).
  #
  # The bonus on those dates is `bps` of each date's base coins (ship approval's allocation of the approved seconds to
  # dates, with deflation, exactly as Coins::ShipPayout does it), summed exactly and floored once, like the streak bonus:
  # floor(sum of base coins of matched dates x bps / 10000). It adds to the base coins and to the streak bonus and is never
  # multiplied by either: it is its own ledger row.
  module Bonus
    # One person's side of the maths. `zone` is an ActiveSupport::TimeZone, `seconds_by_date` { Date => counted seconds }.
    Member = Data.define(:joined_at, :zone, :seconds_by_date) do
      def in_for?(date) = joined_at <= date.in_time_zone(zone)

      def coded?(date, threshold) = seconds_by_date.fetch(date, 0) >= threshold
    end

    Result = Data.define(:bonus_coins, :matched_dates)

    module_function

    # The dates (sorted) on which `earner` is matched by at least one of `crewmates`.
    def matched_dates(dates:, earner:, crewmates:, threshold:)
      Array(dates).map(&:to_date).uniq.sort.select do |date|
        earner.in_for?(date) && crewmates.any? { |mate| mate.in_for?(date) && mate.coded?(date, threshold) }
      end
    end

    # Bonus coins for an approved ship. `coded_seconds_by_date` is the ship's own snapshot ({ Date => seconds });
    # `matched_dates` the dates the bonus applies to (see .matched_dates).
    def coins(approved_seconds:, coded_seconds_by_date:, matched_dates:, bps:, game_config: Game::Config.current)
      return 0 if matched_dates.empty? || bps.zero? || approved_seconds.zero?

      payout = Coins::ShipPayout.call(approved_seconds: approved_seconds, coded_seconds_by_date: coded_seconds_by_date, config: game_config)
      wanted = matched_dates.to_set
      weighted = payout.per_date.sum do |date, row|
        wanted.include?(date) ? Coins::Conversion.units(full_seconds: row[:full_rate_seconds], deflated_seconds: row[:deflated_seconds], config: game_config) * bps : 0
      end
      weighted.div(Coins::Conversion::UNITS_PER_COIN * 10_000)
    end

    def call(approved_seconds:, coded_seconds_by_date:, earner:, crewmates:, threshold:, bps:, eligible_dates: nil, game_config: Game::Config.current)
      dates = coded_seconds_by_date.keys
      dates &= eligible_dates.to_a if eligible_dates
      matched = matched_dates(dates: dates, earner: earner, crewmates: crewmates, threshold: threshold)
      Result.new(bonus_coins: coins(approved_seconds: approved_seconds, coded_seconds_by_date: coded_seconds_by_date, matched_dates: matched, bps: bps,
                                    game_config: game_config), matched_dates: matched)
    end
  end
end
