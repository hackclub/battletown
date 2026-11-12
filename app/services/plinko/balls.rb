module Plinko
  # How many balls a player can drop right now. Nothing about balls is stored: they are worked out from the hours ledger
  # (Hours::Totals, so only counted time from the sign-up date on) and the player's plinko_drops, so nothing can count
  # twice and a correction to the ledger is reflected at once.
  #
  # The rules, walked one local day at a time (`compute`, which is pure and takes plain hashes):
  #   - Balls are earned from cumulative counted seconds: the n-th ball arrives on the first day the running total
  #     reaches n * seconds_per_ball. Leftover minutes carry over to the next day.
  #   - A ball can be dropped on the day it is earned and the days after; it is gone when `ball_expiry_days` days have
  #     passed since the day it was earned. Drops use the oldest ball first.
  #   - At the end of each day the bank keeps at most `max_balls_banked`; a ball over the cap pushes out the oldest.
  #   - A day with a drop dated later than today (a player who moved west) is still walked, so a drop is never undone.
  module Balls
    Result = Data.define(:available, :earned_total, :dropped_total, :seconds_to_next, :full, :last_usable_on) do
      def any? = available.positive?
    end

    module_function

    # The player's balls as of `now`, in their own time zone.
    def for(user, now: Time.current, config: Config.current)
      today = Hours::Days.today(user, now: now)
      first = [ Hours::Days.first_counted_date(user), config.earning_starts_on ].compact.max
      seconds = first > today ? {} : Hours::Totals.seconds_by_date(user, first..today)
      drops = PlinkoDrop.where(user_id: user.id).group(:local_date).count
      compute(daily_seconds: seconds, drops_by_date: drops, today: today, config: config)
    end

    # daily_seconds: { Date => counted seconds }, drops_by_date: { Date => balls dropped that day }.
    def compute(daily_seconds:, drops_by_date:, today:, config: Config.current)
      per = config.seconds_per_ball
      dates = daily_seconds.keys + drops_by_date.keys
      return Result.new(available: 0, earned_total: 0, dropped_total: 0, seconds_to_next: per, full: false, last_usable_on: nil) if dates.empty?

      bank = [] # [day earned, balls], oldest first
      cumulative = 0
      earned_total = 0
      (dates.min..[ today, *drops_by_date.keys ].max).each do |date|
        bank.reject! { |earned_on, _| earned_on + config.ball_expiry_days <= date }
        cumulative += daily_seconds.fetch(date, 0)
        earned = cumulative / per - earned_total
        if earned.positive?
          bank << [ date, earned ]
          earned_total += earned
        end
        spend(bank, drops_by_date.fetch(date, 0))
        trim(bank, config.max_balls_banked)
      end

      available = bank.sum { |_, count| count }
      Result.new(
        available: available, earned_total: earned_total, dropped_total: drops_by_date.values.sum,
        seconds_to_next: per - (cumulative % per), full: available >= config.max_balls_banked,
        last_usable_on: bank.first && (bank.first.first + config.ball_expiry_days - 1)
      )
    end

    # Takes `count` balls from the oldest first (a drop is only ever allowed with a ball available, so the bank never
    # runs short; if a ledger correction left it short, it just empties).
    def spend(bank, count)
      while count.positive? && bank.any?
        taken = [ count, bank.first.last ].min
        count -= taken
        bank.first[1] -= taken
        bank.shift if bank.first.last.zero?
      end
    end

    def trim(bank, cap)
      excess = bank.sum { |_, count| count } - cap
      spend(bank, excess) if excess.positive?
    end
  end
end
