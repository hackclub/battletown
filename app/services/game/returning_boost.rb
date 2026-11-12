module Game
  # The returning-user bonus (feature flag `returning`, config/game.yml `returning:`; docs/CONTRACT.md).
  #
  # A person is "coming back" on a local date when that date is a qualifying day (the 15-minute mark) and the days
  # between their previous qualifying day and this one, not counting either end, number at least `idle_days`. A person
  # who never had a qualifying day before is not coming back: signing up, finishing onboarding or a long quiet start
  # earns nothing. That date opens a WelcomeBackWindow of `boost_days` local dates (it and the ones after it). A window
  # belongs to its idle period alone: the next one needs another idle stretch of `idle_days` after a qualifying day, and
  # a person gets at most `max_windows` over their whole time here.
  #
  # The boost is a FLOOR on the streak bonus of a qualifying day inside a window: `bonus_bps = max(ramp bps, floor_bps)`.
  # It never lowers a higher ramp value, never touches the streak counter or the freeze, and a day without a qualifying
  # 15 minutes keeps bonus 0. It is applied once, when Game::Settle writes the day's immutable DailyResult, so
  # Coins::ApproveShip pays it through the normal streak bonus path (only on approved hours; nothing for unapproved time).
  # A day settled while the flag was off keeps the bonus it was settled with.
  #
  # The rules (`window_starting`, `floor`, `windows`) are pure: dates and numbers in, values out. `Tracker` carries them
  # through one settlement run and is the only writer (windows, idempotently: unique per user and start date).
  # `banner` is what the dashboard reads. Callers check `Features.enabled?(:returning)` first.
  module ReturningBoost
    Config = Data.define(:idle_days, :boost_days, :floor_bps, :max_windows, :nudge_max_idle_days) do
      def self.current
        @current ||= from_hash(Rails.application.config_for(:game))
      end

      def self.reset!
        @current = nil
      end

      def self.from_hash(hash)
        values = hash.fetch(:returning)
        floor = positive(values.fetch(:floor_bps), "returning.floor_bps")
        raise ArgumentError, "game.yml: returning.floor_bps must be at most 10000" if floor > 10_000

        new(idle_days: positive(values.fetch(:idle_days), "returning.idle_days"),
            boost_days: positive(values.fetch(:boost_days), "returning.boost_days"),
            floor_bps: floor,
            max_windows: positive(values.fetch(:max_windows_per_user), "returning.max_windows_per_user"),
            nudge_max_idle_days: positive(values.fetch(:nudge_max_idle_days), "returning.nudge_max_idle_days"))
      end

      def self.positive(value, name)
        raise ArgumentError, "game.yml: #{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?

        value
      end
      private_class_method :positive
    end

    # `ends_on` is inclusive.
    Window = Data.define(:starts_on, :ends_on, :idle_days) do
      def covers?(date) = date.between?(starts_on, ends_on)

      # Local dates left, counting `today` when it is inside the window; 0 when it is over or has not started.
      def days_left(today) = covers?(today) ? (ends_on - today).to_i + 1 : 0
    end

    # What the dashboard shows: the window covering today (stored once the first day back has settled) or, before that,
    # the one today would open. `started` is true when the boost is real today (stored, or today already reached the mark).
    Banner = Data.define(:window, :started, :days_left)

    module_function

    def config = Config.current

    # Whole days with no qualifying day between two qualifying dates.
    def idle_gap(previous_on, date) = (date - previous_on).to_i - 1

    # The window `date` opens, or nil. The caller has already established that `date` is itself a qualifying day.
    def window_starting(previous_on, date, config: self.config)
      return nil unless previous_on && date > previous_on

      gap = idle_gap(previous_on, date)
      return nil if gap < config.idle_days

      Window.new(starts_on: date, ends_on: date + (config.boost_days - 1), idle_days: gap)
    end

    # The streak bonus a qualifying day gets: the ramp value, raised to the floor inside a window, never lowered. A day
    # that earned no bonus (not a qualifying day, or covered by the freeze) stays at 0.
    def floor(bonus_bps, in_window:, config: self.config)
      return bonus_bps unless in_window && bonus_bps.positive?

      [ bonus_bps, config.floor_bps ].max
    end

    # The windows a history of qualifying dates produces, by the same rule Settle applies day by day (for tests and for
    # explaining a result). `dates` need not be sorted.
    def windows(dates, config: self.config)
      found = []
      dates.uniq.sort.each_cons(2) do |previous_on, date|
        break if found.size >= config.max_windows

        window = window_starting(previous_on, date, config: config)
        found << window if window
      end
      found
    end

    # What the dashboard needs for `today`. `today_met`: today's coded time has reached the 15-minute mark so far.
    # Reads only the user's own rows.
    def banner(user, today:, today_met:, config: self.config)
      stored = WelcomeBackWindow.where(user_id: user.id).covering(today).first
      if stored
        window = window_of(stored)
        return Banner.new(window: window, started: true, days_left: window.days_left(today))
      end

      window = projected_window(user, today, config)
      window && Banner.new(window: window, started: today_met, days_left: window.days_left(today))
    end

    # The window today would open if it turns out to be a qualifying day: the previous qualifying day is far enough back
    # and the person still has windows left. Days that have closed but are not settled yet are read from the live ledger.
    def projected_window(user, today, config, source: Game::HoursSource.current)
      return nil if DailyResult.exists?(user_id: user.id, local_date: today)
      return nil if WelcomeBackWindow.where(user_id: user.id).count >= config.max_windows

      settled = DailyResult.where(user_id: user.id)
      last_row = settled.maximum(:local_date)
      previous_on = settled.where(quick_met: true, local_date: ...today).maximum(:local_date)
      if last_row.nil? || last_row < today - 1
        from = last_row ? last_row + 1 : Hours::Days.first_counted_date(user)
        if from < today
          live = source.seconds_by_date(user, from..(today - 1)).select { |_, seconds| seconds >= Game::Config.current.quick_seconds }.keys.max
          previous_on = [ previous_on, live ].compact.max
        end
      end
      window_starting(previous_on, today, config: config)
    end

    def window_of(row) = Window.new(starts_on: row.starts_on, ends_on: row.ends_on, idle_days: row.idle_days)

    # Walks the days of one Settle run, in date order, inside the user lock. Reads the user's last qualifying date before
    # the run and their windows once.
    class Tracker
      def initialize(user, before:, config: ReturningBoost.config)
        @user = user
        @config = config
        @previous_on = DailyResult.where(user_id: user.id, quick_met: true).where(local_date: ...before).maximum(:local_date)
        @windows = WelcomeBackWindow.where(user_id: user.id).order(:starts_on).map { |row| ReturningBoost.window_of(row) }
      end

      # The bonus to store for a settled day. `result` is the StreakCalculator::Result for `date`.
      def bonus_for(date, result)
        return result.bonus_bps unless result.quick_met

        open_window(date)
        covered = @windows.any? { |window| window.covers?(date) }
        @previous_on = date
        ReturningBoost.floor(result.bonus_bps, in_window: covered, config: @config)
      end

      private

      def open_window(date)
        return if @windows.size >= @config.max_windows

        window = ReturningBoost.window_starting(@previous_on, date, config: @config)
        return unless window

        # Settle holds the user's row lock, so nobody else writes this user's windows; the savepoint and the unique
        # index are the belt and braces that keep a repeated run from ever making a second row.
        row = WelcomeBackWindow.transaction(requires_new: true) do
          WelcomeBackWindow.find_or_create_by!(user_id: @user.id, starts_on: window.starts_on) do |new_row|
            new_row.ends_on = window.ends_on
            new_row.idle_days = window.idle_days
          end
        end
        @windows << ReturningBoost.window_of(row)
      rescue ActiveRecord::RecordNotUnique
        @windows << ReturningBoost.window_of(WelcomeBackWindow.find_by!(user_id: @user.id, starts_on: window.starts_on))
      end
    end
  end
end
