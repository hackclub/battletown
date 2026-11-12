module MerchTrack
  # How far one person is through one boss week's goal days. Reads only: the settled `daily_results` rows
  # (Game::Settle writes them) and the clock the caller passes. Pure in the sense that nothing is written.
  #
  # Counting rules, per local date of the boss's week (the person's own calendar dates, see Hours::Days):
  #   met          settled, goal_met, and not covered by the freeze (a frozen day is NOT a goal day: the freeze only
  #                protects the 15-minute streak, so a day it covered with goal_met false stays a miss, and a row that
  #                ever had both is not counted either).
  #   missed       settled and the goal was not met.
  #   pending      today, or a day that has ended but is not settled yet (it settles at local midnight plus the grace
  #                period, so a late Hackatime sync can still land on it). Never counted until it settles.
  #   future       a date after the person's local today.
  #   not_counted  before the person's first counted date (the day the account was created): never counts, see
  #                Hours::Days.first_counted_date.
  # `earned?` is true once `days_required` days are met. Days that are not settled never count towards it.
  class Progress
    STATES = %i[met missed pending future not_counted].freeze

    Day = Data.define(:date, :state, :today)

    attr_reader :boss, :item, :required, :days

    # `now:` is the instant the page is for. `config:` is the MerchTrack::Config.
    def self.for(user, boss, now: Time.current, config: Config.current)
      new(user, boss, now: now, config: config)
    end

    def initialize(user, boss, now:, config:)
      @boss = boss
      @required = config.days_required
      @item = Track.item_for(boss, config: config)
      @days = build_days(user, now)
    end

    def met = days.count { |day| day.state == :met }

    def pending = days.count { |day| day.state == :pending }

    def open_days = days.count { |day| %i[pending future].include?(day.state) }

    def earned? = met >= required

    # Goal days still needed (0 once earned).
    def to_go = [ required - met, 0 ].max

    # Whether the week can still be earned: enough days are met or still to play (pending days may still turn out met).
    def reachable? = met + open_days >= required

    private

    def build_days(user, now)
      today = Hours::Days.today(user, now: now)
      first = Hours::Days.first_counted_date(user)
      results = DailyResult.where(user_id: user.id, local_date: boss.range).index_by(&:local_date)
      boss.range.map { |date| Day.new(date: date, state: state_for(date, results[date], today, first), today: date == today) }
    end

    def state_for(date, result, today, first)
      return :not_counted if date < first
      return (result.goal_met && !result.freeze_used ? :met : :missed) if result

      date > today ? :future : :pending
    end
  end
end
