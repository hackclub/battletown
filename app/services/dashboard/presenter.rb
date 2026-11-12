require "bigdecimal"

module Dashboard
  # Everything the signed-in home page shows, as plain values and ready-made sentences (no ActiveRecord objects leak
  # into the view, and the view has no rules of its own). Build one per request:
  #
  #   dashboard = Dashboard::Presenter.new(user: current_user)
  #   render "bosses/card", presenter: dashboard.boss
  #
  # `now:` is the instant the page is for; "today" is the user's own local date at that instant. Sections are read
  # lazily and memoised, so a section the page does not ask for costs nothing.
  #
  # Honesty rules baked in: a streak bonus is only ever called "projected" until the day has closed and settled; only
  # the user's own numbers appear here, plus the boss card's community headcount (an aggregate, no names).
  class Presenter
    Today = Data.define(:date, :seconds, :minutes, :goal_minutes, :quick_minutes, :quick_met, :goal_met, :progress_max,
                        :progress_value, :progress_text, :meter_text, :goal_smashed, :quick_text, :bonus_message, :first_run)

    # One streak card. `state` is :empty, :active, :broken or :frozen. Nil entries mean "show nothing".
    StreakCard = Data.define(:state, :days, :title, :headline, :message, :today_bonus_text, :next_bonus_text, :best_text,
                             :freeze_text, :freeze_ready)

    # The welcome-back banner of the returning-user bonus (feature flag `returning`): shown only while the boost is real.
    ReturningBanner = Data.define(:title, :message, :days_left)

    CoinsPanel = Data.define(:total, :spendable, :total_text, :spendable_text, :show_spendable, :locked, :verification_status, :has_orders)

    ShipSummary = Data.define(:id, :status, :label, :message, :reason, :open)

    ProjectPanel = Data.define(:id, :name, :linked_count, :linked_text, :window_seconds, :window_text, :min_text, :readiness,
                               :reason, :can_ship, :ship)

    HackatimePanel = Data.define(:state, :title, :message)

    PrizePanel = Data.define(:name, :emoji, :price_coins, :price_text, :hours_text, :balance, :progress_value, :progress_text,
                             :message, :reached, :free)

    HACKATIME_COPY = {
      connected: [ "Connected", "Your coding time counts toward the boss automatically." ],
      needs_reconnect: [ "Needs reconnecting", "Hackatime stopped accepting our access, so your time isn't syncing right now. Connect again to pick up where you left off." ],
      not_connected: [ "Not connected", "Connect Hackatime and your coding time counts toward the boss automatically. It is optional: you can keep coding without it." ]
    }.freeze

    attr_reader :user, :now

    def initialize(user:, now: Time.current)
      @user = user
      @now = now
    end

    # --- header ---

    def name = user.display_name.presence || "adventurer"

    def today_date = @today_date ||= Hours::Days.today(user, now: now)

    # "Tuesday 11 November"
    def date_text = today_date.strftime("%A %-d %B")

    # --- the weekly boss (render with the bosses/card partial) ---

    def boss = @boss ||= Bosses::Presenter.new(user: user, today: today_date)

    # --- today ---

    def today
      @today ||= build_today
    end

    # --- streaks ---

    def quick_streak = @quick_streak ||= build_quick_streak

    def goal_streak = @goal_streak ||= build_goal_streak

    # --- the weekly merch track (flag `merch_track`; nil while it is off or when no week has an item to show) ---

    def merch_track
      return unless Features.enabled?(:merch_track)
      return @merch_track if defined?(@merch_track)

      @merch_track = MerchTrack::Panel.for(user, today: today_date, now: now)
    end

    # --- the returning-user bonus (nil unless the `returning` flag is on and the boost is live today) ---

    def returning_banner
      return @returning_banner if defined?(@returning_banner)

      @returning_banner = build_returning_banner
    end

    # --- coins ---

    def coins
      @coins ||= begin
        total = ::Coins::Balance.total(user)
        spendable = Shop::Spendable.unlocked?(user) ? total : 0
        CoinsPanel.new(total: total, spendable: spendable, total_text: coins_text(total), spendable_text: coins_text(spendable),
                  show_spendable: spendable != total, locked: Shop::Spendable.locked?(user), verification_status: user.verification_status,
                  has_orders: user.orders.exists?)
      end
    end

    # --- the active project (nil when the user has none) ---

    def project
      return @project if defined?(@project)

      @project = build_project
    end

    # --- Hackatime ---

    def hackatime
      @hackatime ||= begin
        connection = user.hackatime_connection
        state = if connection.nil? then :not_connected
        elsif connection.needs_reconnect? then :needs_reconnect
        else :connected
        end
        HackatimePanel.new(state: state, title: HACKATIME_COPY.fetch(state).first, message: HACKATIME_COPY.fetch(state).last)
      end
    end

    # --- the chosen prize (nil when none is chosen) ---

    def prize
      return @prize if defined?(@prize)

      @prize = build_prize
    end

    # Plain text helpers other code (tests) may want.
    def self.minutes_text(minutes) = "#{minutes} #{minutes == 1 ? 'minute' : 'minutes'}"

    def self.days_text(days) = "#{days} #{days == 1 ? 'day' : 'days'}"

    # "5", "7", "8.1" for basis points.
    def self.percent_text(bps) = "#{format('%g', bps / 100.0)}%"

    private

    def config = Game::Config.current

    def streaks = @streaks ||= Streaks.call(user: user, today: today_date, config: config)

    # The welcome-back window that covers today, or the one today would open (nil with the flag off or when none).
    def returning
      return @returning if defined?(@returning)

      @returning = Features.enabled?(:returning) ? Game::ReturningBoost.banner(user, today: today_date, today_met: streaks.quick_today_met) : nil
    end

    # The streak bonus a day with streak day `streak_day` is projected to earn on `date`, with the welcome-back floor.
    def projected_bps(streak_day, date)
      Game::ReturningBoost.floor(Game::BonusRamp.bps(streak_day, config: config), in_window: !!returning&.window&.covers?(date))
    end

    def build_returning_banner
      info = returning
      return unless info&.started

      floor = self.class.percent_text(Game::ReturningBoost.config.floor_bps)
      left = info.days_left
      ReturningBanner.new(title: "Welcome back!", days_left: left,
                          message: "Your streak bonus is boosted for #{left} more #{left == 1 ? 'day' : 'days'}. " \
                                   "On each day you code #{config.quick_seconds / 60} minutes it is at least #{floor}.")
    end

    def coins_text(amount) = "#{ActiveSupport::NumberHelper.number_to_delimited(amount)} #{amount == 1 ? 'coin' : 'coins'}"

    # --- today ---

    def build_today
      snap = streaks
      seconds = snap.today_seconds
      quick_minutes = config.quick_seconds / 60
      goal_minutes = config.goal_seconds / 60
      minutes = seconds / 60
      # The bar and its numbers stop at the goal ("420 of 60" reads like a bug); a day past it gets its own words.
      progress_text = "#{[ minutes, goal_minutes ].min} of #{self.class.minutes_text(goal_minutes)}"
      goal_smashed = minutes > goal_minutes
      Today.new(date: today_date, seconds: seconds, minutes: minutes, goal_minutes: goal_minutes, quick_minutes: quick_minutes,
                quick_met: snap.quick_today_met, goal_met: snap.goal_today_met, progress_max: config.goal_seconds,
                progress_value: [ seconds, config.goal_seconds ].min, progress_text: progress_text,
                meter_text: goal_smashed ? "Goal smashed! #{self.class.minutes_text(minutes)} today." : "#{progress_text} (your daily goal)",
                goal_smashed: goal_smashed,
                quick_text: quick_text(snap, seconds, quick_minutes), bonus_message: bonus_message(snap, quick_minutes),
                first_run: !HourEntry.exists?(user_id: user.id))
    end

    def quick_text(snap, seconds, quick_minutes)
      return "#{quick_minutes}-minute mark reached" if snap.quick_today_met

      to_go = ((config.quick_seconds - seconds) / 60.0).ceil
      "#{self.class.minutes_text(to_go)} to go for the #{quick_minutes}-minute mark"
    end

    # The bonus for today is projected from the streak as it stood when today began. It is never final before the
    # day is settled, so the words always say "once the day closes".
    def bonus_message(snap, quick_minutes)
      percent = self.class.percent_text(projected_bps(snap.carried_quick + 1, today_date))
      if snap.quick_today_met
        "You've hit #{quick_minutes} minutes. Today's bonus is on track for #{percent}, confirmed once the day closes."
      elsif snap.carried_quick.positive?
        "Hit #{quick_minutes} minutes to keep your streak: today's bonus is #{percent} once the day closes."
      else
        "Hit #{quick_minutes} minutes to start a streak: today's bonus is #{percent} once the day closes."
      end
    end

    # --- streaks ---

    def build_quick_streak
      snap = streaks
      days = snap.quick_days
      state = if days.positive? then (snap.last_day_frozen && !snap.quick_today_met ? :frozen : :active)
      elsif snap.best_quick.positive? then :broken
      else :empty
      end
      mark = config.quick_seconds / 60
      today_bps = projected_bps(snap.carried_quick + 1, today_date)
      next_bps = projected_bps(snap.carried_quick + 2, today_date + 1)
      StreakCard.new(
        state: state, days: days, title: "#{mark}-minute streak", headline: streak_headline(state, days),
        message: quick_message(state, snap, days, mark, self.class.percent_text(next_bps)),
        today_bonus_text: "Today's bonus: #{self.class.percent_text(today_bps)} once the day closes",
        next_bonus_text: "Next day: #{self.class.percent_text(next_bps)}",
        best_text: (snap.best_quick > days ? "Best: #{self.class.days_text(snap.best_quick)}" : nil),
        freeze_text: freeze_text(snap), freeze_ready: snap.freeze_ready
      )
    end

    def streak_headline(state, days)
      case state
      when :empty then "No streak yet"
      when :broken then "A fresh start"
      else self.class.days_text(days)
      end
    end

    def quick_message(state, snap, days, mark, next_percent)
      case state
      when :empty then "Code for #{mark} minutes to start your streak."
      when :frozen then "Your freeze kept your streak alive. Code #{mark} minutes today to keep it going."
      when :broken then "A fresh start. Your best was #{self.class.days_text(snap.best_quick)}. Code #{mark} minutes today to begin a new streak."
      else
        if snap.quick_today_met
          "Today counts. Come back tomorrow for day #{days + 1}, worth #{next_percent}."
        else
          "Code #{mark} minutes today to reach day #{days + 1}."
        end
      end
    end

    def freeze_text(snap)
      if snap.freeze_ready
        "Freeze ready"
      elsif snap.freeze_used_on
        "Freeze used on #{snap.freeze_used_on.strftime('%-d %b')}"
      else
        "Freeze not ready yet"
      end
    end

    def build_goal_streak
      snap = streaks
      days = snap.goal_days
      goal = config.goal_seconds / 60
      state = if days.positive? then :active
      elsif snap.best_goal.positive? then :broken
      else :empty
      end
      message = case state
      when :empty then "Code for #{goal} minutes in one day to start this streak."
      when :broken then "A fresh start. Your best was #{self.class.days_text(snap.best_goal)}. Code #{goal} minutes today to begin again."
      else snap.goal_today_met ? "Today's goal is done. See you tomorrow." : "Code #{goal} minutes today to reach day #{days + 1}."
      end
      StreakCard.new(state: state, days: days, title: "#{goal}-minute daily goal streak", headline: streak_headline(state, days),
                     message: message, today_bonus_text: nil, next_bonus_text: nil,
                     best_text: (snap.best_goal > days ? "Best: #{self.class.days_text(snap.best_goal)}" : nil),
                     freeze_text: nil, freeze_ready: nil)
    end

    # --- project ---

    def build_project
      active = user.active_project
      return unless active

      links = active.hackatime_links.to_a
      window = Ships::Window.call(active)
      min_seconds = Ships::Config.current.min_seconds
      latest = active.ships.newest_first.first
      readiness = project_readiness(links, window, min_seconds, latest)
      ProjectPanel.new(id: active.id, name: active.name, linked_count: links.size,
                       linked_text: links.empty? ? "No Hackatime project linked yet" : "#{links.size} Hackatime #{links.size == 1 ? 'project' : 'projects'} linked",
                       window_seconds: window.seconds, window_text: window.empty? ? "0 minutes" : duration_text(window.seconds), min_text: hours_text(min_seconds),
                       readiness: readiness, reason: readiness_reason(readiness, window.seconds, min_seconds),
                       can_ship: readiness == :ready, ship: latest && ship_summary(latest))
    end

    def project_readiness(links, window, min_seconds, latest)
      return :ship_open if latest&.open?
      return :no_link if links.empty?
      return :no_hours if window.empty?

      window.seconds < min_seconds ? :too_few : :ready
    end

    def readiness_reason(readiness, seconds, min_seconds)
      case readiness
      when :no_link then "Link a Hackatime project to this project first, so we know which of your coding time to ship."
      when :no_hours then "No coded time on this project since your last ship yet. Code on a linked Hackatime project and it shows up here."
      when :too_few
        "You need at least #{hours_text(min_seconds)} on this project to ship. You have #{duration_text(seconds)} so far, " \
          "#{duration_text(min_seconds - seconds)} to go."
      end
    end

    def ship_summary(ship)
      label = ShipsHelper::STATUS_LABELS.fetch(ship.status)
      message = case ship.status
      when "draft" then "You have a draft ship. Continue it when you're ready to send it for review."
      when "submitted" then "Your ship is waiting for review. A staff member will take a look soon."
      when "approved" then "#{hours_text(ship.approved_seconds)} approved, #{coins_text(ship.coin_breakdown[:total])} earned."
      when "rejected" then "This ship needs changes before it can be approved."
      else "You withdrew this ship. The time you coded is free for your next one."
      end
      ShipSummary.new(id: ship.id, status: ship.status, label: label, message: message,
                      reason: (ship.rejection_reason if ship.status_rejected?), open: ship.open?)
    end

    # "2 hours 5 minutes", "less than a minute".
    def duration_text(seconds) = Bosses::Presenter.human_duration([ seconds, 0 ].max)

    # "1 hour", "1.5 hours", "0.25 hours".
    def hours_text(seconds)
      value = (BigDecimal(seconds) / 3600).round(2).to_f
      shown = (value % 1).zero? ? value.to_i : value
      "#{shown} #{shown == 1 ? 'hour' : 'hours'}"
    end

    # --- prize ---

    def build_prize
      chosen = user.prize
      return unless chosen

      balance = coins.total
      if chosen.free_signup? || chosen.coins.zero?
        return PrizePanel.new(name: chosen.name, emoji: chosen.emoji, price_coins: 0, price_text: "Free", hours_text: nil, balance: balance,
                              progress_value: 0, progress_text: nil, message: "This one is free: claim it in the shop.", reached: true, free: true)
      end

      value = [ balance, chosen.coins ].min
      reached = balance >= chosen.coins
      message = if reached
        "You have enough coins for this prize."
      else
        "#{coins_text(chosen.coins - balance)} to go, about #{hours_text_of_coins(chosen.coins - balance)} of approved coding."
      end
      PrizePanel.new(name: chosen.name, emoji: chosen.emoji, price_coins: chosen.coins, price_text: coins_text(chosen.coins),
                     hours_text: chosen.hours_text, balance: balance, progress_value: value,
                     progress_text: "#{ActiveSupport::NumberHelper.number_to_delimited(value)} of #{coins_text(chosen.coins)}",
                     message: message, reached: reached, free: false)
    end

    # Coins to approved hours at the plain rate (no streak bonus), one decimal at most, rounded up so it is never
    # promised sooner than it can happen.
    def hours_text_of_coins(coins)
      tenths = (coins * 10r / config.coins_per_hour).ceil
      value = (tenths % 10).zero? ? tenths / 10 : tenths / 10.0
      "#{value} #{value == 1 ? 'hour' : 'hours'}"
    end
  end
end
