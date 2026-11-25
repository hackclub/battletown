module DevSimulator
  # Makes simulated players ship, the way the app does it: each ship gets a fresh project of the player's with its own linked
  # Hackatime name, the hours are written to the ledger under that name (Hours::Credit, source "manual", over today and the
  # days just before it, inside the backfill window and never past the daily cap) and Ships::Submit turns them into a submitted ship.
  # Submit runs the same defeat check a real ship does, so the boss falls here exactly when it would for real.
  #
  # The ledger holds at most one daily cap of hours per day over the backfill window, far less than the biggest ship here
  # (MAX_HOURS), so only what fits is credited that way; the rest of the ship's hours is written as "adjustment" rows (the one
  # source that is not capped, in chunks of at most one day each) on today. That way a big hit always lands in full.
  #
  # A player holds at most Project::MAX_PER_USER projects and a project holds one ship until staff decide it, so a player
  # runs out after about ten ships: that is counted under `skipped` (:no_project), as is a ship the app refused (:refused).
  #
  #   mode "all"      every simulated player
  #   mode "percent"  that percent of them, picked at random (`percent` 1..100)
  #   mode "count"    that many of them, picked at random (`count` 1..MAX_CREATE)
  #
  # `hours_min`..`hours_max` is the range one ship's hours are drawn from (whole minutes): at least the hours a ship needs
  # (ships.min_hours), at most MAX_HOURS. Anything outside that is refused, not trimmed.
  class Ship
    Result = Data.define(:shipped, :skipped, :seconds, :players)

    MODES = %w[all percent count].freeze

    def self.call(**args) = new(**args).call

    def initialize(mode:, today:, percent: 30, count: 3, hours_min: DEFAULT_HOURS_MIN, hours_max: DEFAULT_HOURS_MAX, random: Random.new, config: ::Ships::Config.current)
      @mode = mode.to_s
      @today = today
      @percent = percent
      @count = count
      @hours_min = hours_min
      @hours_max = hours_max
      @random = random
      @config = config
    end

    def call
      DevSimulator.check_local_database!
      raise Refused, "mode must be one of #{MODES.join(', ')}" unless MODES.include?(@mode)

      range = seconds_range
      ids = chosen_ids
      raise Refused, "No players yet: create some first." if ids.empty?

      skipped = Hash.new(0)
      shipped = 0
      shipped_seconds = 0
      ids.each do |id|
        outcome = ship_one(User.find(id), @random.rand(range) / 60 * 60)
        if outcome.is_a?(Symbol)
          skipped[outcome] += 1
        else
          shipped += 1
          shipped_seconds += outcome.coded_seconds # what the ship really holds: the damage the boss takes
        end
      end
      Result.new(shipped: shipped, skipped: skipped.to_h, seconds: shipped_seconds, players: ids.size)
    end

    private

    def seconds_range
      min = hours(@hours_min, "hours per ship (min)")
      max = hours(@hours_max, "hours per ship (max)")
      raise Refused, "hours per ship (min) cannot be above the max" if min > max

      min..max
    end

    # Hours (a number or a numeric string) as seconds, inside what one ship may hold.
    def hours(value, name)
      number = Float(value.to_s.strip, exception: false)
      floor = (@config.min_seconds / 3600.0).round(2)
      floor = floor.to_i if floor == floor.to_i
      raise Refused, "#{name} must be a number from #{floor} to #{MAX_HOURS}" unless number && number >= floor && number <= MAX_HOURS

      (number * 3600).round
    end

    def chosen_ids
      ids = DevSimulator.players.order(:id).pluck(:id)
      case @mode
      when "all" then ids
      when "percent"
        percent = DevSimulator.whole_number(@percent, 1..100, "percent")
        ids.shuffle(random: @random).first((ids.size * percent / 100.0).ceil)
      else
        ids.shuffle(random: @random).first(DevSimulator.whole_number(@count, 1..MAX_CREATE, "count"))
      end
    end

    # The submitted ship, or why not as a symbol: :no_project, :refused.
    def ship_one(player, seconds)
      project = free_project(player)
      return :no_project unless project

      plan = plan_credits(player, seconds)
      name = link_name(project)
      plan.each do |date, part|
        Hours::Credit.call(user: player, seconds: part, source: "manual", local_date: date, hackatime_project: name, note: "Simulated ship hours",
                           created_by: CREATED_BY, idempotency_key: "sim:ship:#{project.id}:#{date.iso8601}")
      end
      credit_overflow(player, project, name, seconds - plan.sum(&:last))
      ship = ::Ships::Submit.call(project: project, attributes: { description: "A simulated ship.", repo_url: "https://github.com/sim-players/sim-#{project.id}" }, submit: true)
      ship.persisted? && ship.status_submitted? ? ship : :refused
    rescue Hours::Credit::Rejected, ::Ships::Submit::Refused
      :refused
    end

    # A project of the player's that has never shipped, or a new one while they have room for it.
    def free_project(player)
      used = ::Ship.where(user_id: player.id).select(:project_id)
      project = player.projects.where.not(id: used).order(:id).first
      return project if project
      return if player.projects.count >= Project::MAX_PER_USER

      Project.create!(user: player, name: "Sim project #{player.projects.count + 1}", kind: "game")
    end

    def link_name(project)
      project.hackatime_links.order(:id).first&.hackatime_project ||
        project.hackatime_links.create!(user: project.user, hackatime_project: "sim-#{project.user.hca_uid.delete_prefix(UID_PREFIX)}-#{project.id}", link_method: "manual").hackatime_project
    end

    # The hours the capped days could not hold, as adjustment rows on today (an adjustment is never clamped), one day's worth at most per row.
    def credit_overflow(player, project, name, left)
      index = 0
      while left.positive?
        part = [ left, HourEntry::MAX_SECONDS ].min
        Hours::Credit.call(user: player, seconds: part, source: "adjustment", local_date: @today, hackatime_project: name, note: "Simulated ship hours over the daily cap",
                           created_by: CREATED_BY, idempotency_key: "sim:ship:over:#{project.id}:#{index}")
        left -= part
        index += 1
      end
    end

    # [[date, seconds]]: today first, then the days before it (one fewer than the backfill window allows, so a player whose zone is a day
    # ahead of yours is still inside it), each day only up to what the daily cap still allows, and never a day that no ship counts
    # (before the player's first counted date or the program's project time cutoff).
    def plan_credits(player, seconds)
      hours_config = Hours::Config.current
      first = ::Ships::Window.first_date(player, config: @config)
      left = seconds
      (0...hours_config.max_backfill_days).each_with_object([]) do |back, plan|
        next if left <= 0

        date = @today - back
        next if date < first
        room = hours_config.daily_cap_seconds - HourEntry.where(user_id: player.id, local_date: date).sum(:seconds)
        part = [ left, room ].min
        next unless part.positive?

        left -= part
        plan << [ date, part ]
      end
    end
  end
end
