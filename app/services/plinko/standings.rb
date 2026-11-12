module Plinko
  # Everything the Plinko page shows about points, for one player (the viewer):
  #   - their own points today, this week (Friday to Thursday, in their local dates) and all time, and the last 7 days;
  #   - the weekly leaderboard: only players who opted in, by nickname and points, nothing else;
  #   - their own rank this week, shown to them only, whether or not they opted in (it counts every player who scored).
  #
  # Points are the sum of `plinko_drops.points`, dated by the local day each ball was dropped. Plinko points never
  # become coins.
  class Standings
    Row = Data.define(:nickname, :points, :you)
    Day = Data.define(:date, :drops, :points)
    Rank = Data.define(:position, :players)

    attr_reader :today, :week

    def initialize(user, player: nil, now: Time.current, config: Config.current)
      @user = user
      @player = player
      @config = config
      @today = Hours::Days.today(user, now: now)
      @week = Week.range(@today)
    end

    def today_points = own.fetch(@today, [ 0, 0 ]).last

    def week_points = @week_points ||= own.sum { |date, (_, points)| @week.cover?(date) ? points : 0 }

    def total_points = own.sum { |_, (_, points)| points }

    def total_drops = own.sum { |_, (count, _)| count }

    # The last 7 days, newest first, including days with no drops.
    def days
      (0..6).map { |back| @today - back }.map { |date| Day.new(date: date, drops: own.fetch(date, [ 0, 0 ]).first, points: own.fetch(date, [ 0, 0 ]).last) }
    end

    # Top players this week by points: opted-in players only, nickname and points only.
    def leaderboard
      @leaderboard ||= begin
        mine = @player&.leaderboard_opt_in ? @player.nickname : nil
        PlinkoDrop.joins("INNER JOIN plinko_players ON plinko_players.user_id = plinko_drops.user_id")
                  .where(local_date: @week, plinko_players: { leaderboard_opt_in: true })
                  .group("plinko_players.nickname")
                  .having("SUM(plinko_drops.points) > 0")
                  .order(Arel.sql("SUM(plinko_drops.points) DESC, plinko_players.nickname ASC"))
                  .limit(@config.leaderboard_size)
                  .pluck(Arel.sql("plinko_players.nickname"), Arel.sql("SUM(plinko_drops.points)"))
                  .map { |nickname, points| Row.new(nickname: nickname, points: points.to_i, you: nickname == mine) }
      end
    end

    # The viewer's own place among everyone who scored this week (nil before their first point). Counts, never names.
    def rank
      return nil unless week_points.positive?

      this_week = PlinkoDrop.where(local_date: @week)
      ahead = this_week.group(:user_id).having("SUM(points) > ?", week_points).count.size
      Rank.new(position: ahead + 1, players: this_week.distinct.count(:user_id))
    end

    private

    # { Date => [drops, points] } for the viewer.
    def own
      @own ||= PlinkoDrop.where(user_id: @user.id).group(:local_date).pluck(:local_date, Arel.sql("COUNT(*)"), Arel.sql("SUM(points)"))
                         .to_h { |date, count, points| [ date, [ count.to_i, points.to_i ] ] }
    end
  end
end
