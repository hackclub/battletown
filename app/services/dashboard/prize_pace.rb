module Dashboard
  # "Am I on track for my prize?": the coins still missing, turned into coding time at what an approved hour is worth to this
  # person right now (the base rate plus the streak bonus, or the welcome-back floor, that applies today), and judged against
  # the pace they pledged (User#pace_minutes a day on their coding days), the way Save Point judges a daily pace.
  #
  #   * Progress is the coins already in the balance plus the time coded on the active project since its last ship (it turns
  #     into coins when the ship is approved), valued at today's rate. So the bonus shortens the time left, never the price.
  #   * "To go" is held at today's bonus: it does not assume the streak keeps climbing.
  #   * Status: :reached (enough coins, or enough coded time that shipping will do it), :starting (their first counted day,
  #     no verdict yet), :on_track (the last days, up to a week, add up to at least the pledge for those days) or :behind.
  #   * The finish date is where the pledge, not the recent pace, would land (a plan, not a promise).
  #
  # It is an estimate: the real payout bonus is paid per settled day, deflates after six hours on one ship, and crew or quest
  # bonuses are not counted. Nothing here is stored. Nil when no prize is chosen or the prize is free.
  class PrizePace
    Status = Data.define(:state, :badge, :to_go, :bonus, :plan, :bonus_percent)

    WEEK = 7

    def self.for(presenter) = new(presenter).status

    def initialize(presenter)
      @presenter = presenter
    end

    def status
      prize = @presenter.prize
      return if prize.nil? || prize.free

      rate = coins_per_hour_milli
      progress_coins = prize.balance + coded_unshipped_coins(rate)
      to_go_coins = [ prize.price_coins - progress_coins, 0 ].max
      state = state_for(to_go_coins, prize)
      seconds_to_go = (to_go_coins * 3600 * 1000 / rate.to_r / 60).ceil * 60 # up to the next whole minute: never promised sooner than it can happen

      Status.new(state: state, badge: BADGES.fetch(state), to_go: to_go_text(state, prize, seconds_to_go), bonus: bonus_text,
                 plan: plan_text(state, seconds_to_go), bonus_percent: bonus_bps)
    end

    BADGES = { reached: "Enough for it", starting: "Just starting", on_track: "On track", behind: "Behind" }.freeze

    private

    def user = @presenter.user

    def today = @presenter.today_date

    def config = Game::Config.current

    def bonus_bps = @presenter.active_bonus_bps

    # Coins per coded, approved hour times 1000 (an integer, so nothing here is a float).
    def coins_per_hour_milli = config.coins_per_hour * (10_000 + bonus_bps) / 10

    def coded_unshipped_coins(rate)
      seconds = @presenter.project&.window_seconds.to_i
      (seconds * rate / 3600 / 1000)
    end

    def state_for(to_go_coins, _prize)
      return :reached if to_go_coins.zero?
      return :starting if days_counted < 2

      recent_minutes >= pledge_minutes_for_window ? :on_track : :behind
    end

    def to_go_text(state, prize, seconds)
      return (@presenter.coins.total >= prize.price_coins ? "You have the coins. Spend them in the shop." : "Ship your time and you have the coins.") if state == :reached

      "About #{Bosses::Presenter.human_duration(seconds)} of coding to go"
    end

    def bonus_text
      return if bonus_bps.zero?

      "with your #{Dashboard::Presenter.percent_text(bonus_bps)} bonus"
    end

    def plan_text(state, seconds)
      return if state == :reached

      "At #{pace} minutes a day, #{finish_text(seconds)}"
    end

    def finish_text(seconds)
      week_seconds = pledged_week_minutes * 60
      days = (seconds * WEEK / week_seconds.to_r).ceil
      date = today + [ days, 1 ].max
      "around #{date.strftime('%-d %b')}"
    end

    def pace = user.pace

    # How many days a week they said they would code (all seven when they never picked any).
    def days_per_week
      count = user.coding_days.to_s(2).count("1")
      count.zero? ? WEEK : count
    end

    def pledged_week_minutes = pace * days_per_week

    # The pledge over the days that count so far, up to a week, so a new person is not "behind" on day two.
    def days_counted = [ [ (today - Hours::Days.first_counted_date(user)).to_i + 1, 1 ].max, WEEK ].min

    def pledge_minutes_for_window = pledged_week_minutes * days_counted / WEEK.to_f

    def recent_minutes
      range = (today - (days_counted - 1))..today
      Game::HoursSource.current.seconds_by_date(user, range).values.sum / 60.0
    end
  end
end
