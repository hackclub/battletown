module Plinko
  # Aggregate numbers for /admin/plinko: counts only, never a name, nickname, email or id. Dates are the players' local
  # dates on the drops, "today" is the UTC date (like AdminMetrics), so the newest day is still filling in.
  class AdminStats
    DAYS = 28
    WEEKS = 8

    Day = Data.define(:date, :drops, :players, :points)
    WeekRow = Data.define(:starts_on, :ends_on, :drops, :players, :points, :partial)
    Totals = Data.define(:drops, :players, :on_leaderboard, :points)
    Stats = Data.define(:today, :totals, :daily, :weekly)

    AGGREGATES = [ Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT user_id)"), Arel.sql("COALESCE(SUM(points), 0)") ].freeze

    def self.call(today: Time.current.utc.to_date) = new(today).call

    def initialize(today)
      @today = today
    end

    def call
      Stats.new(today: @today, totals: totals, daily: daily, weekly: weekly)
    end

    private

    def totals
      drops, players, points = PlinkoDrop.pluck(*AGGREGATES).first
      Totals.new(drops: drops, players: players, on_leaderboard: PlinkoPlayer.where(leaderboard_opt_in: true).count, points: points)
    end

    # One grouped query for the whole range.
    def daily
      from = @today - (DAYS - 1)
      rows = PlinkoDrop.where(local_date: from..@today).group(:local_date).pluck(:local_date, *AGGREGATES)
                       .to_h { |date, drops, players, points| [ date, [ drops, players, points ] ] }
      (from..@today).map { |date| Day.new(date: date, **%i[drops players points].zip(rows.fetch(date, [ 0, 0, 0 ])).to_h) }
    end

    def weekly
      this_week = Plinko::Week.range(@today)
      (0...WEEKS).map { |back| this_week.begin - (7 * back) }.reverse.map do |starts_on|
        range = starts_on..(starts_on + 6)
        drops, players, points = PlinkoDrop.where(local_date: range).pluck(*AGGREGATES).first
        WeekRow.new(starts_on: starts_on, ends_on: range.end, drops: drops, players: players, points: points, partial: range.cover?(@today))
      end
    end
  end
end
