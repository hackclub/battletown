module Quests
  # The fixed menu of quest goals. Each goal is a small pure-ish checker over data the app already holds (the hours
  # ledger, ships, projects, Hackatime links); there is no free-text goal and nobody reviews a quest by hand.
  #
  #   Quests::Goals.check(user, quest)  # => Progress(current:, target:, completed_at:)
  #
  # `current` is how far the user is (capped at `target`), `completed_at` is the FIRST MOMENT the goal held, worked out
  # from the ledger (never the time somebody looked), or nil while it does not. A quest week is a boss week: whole
  # LOCAL dates `starts_on..ends_on` in the user's time zone (hours are already stored on their frozen local dates, and
  # hours dated before the user signed up count for nothing: Hours::Totals). Goals read what the data shows now, so a
  # correction that takes time away can lower `current`; a completion that was already recorded is never undone.
  module Goals
    KEYS = %w[code_days streak_days ship_project link_hackatime add_project].freeze

    Progress = Data.define(:current, :target, :completed_at) do
      def complete? = !completed_at.nil?
    end

    module_function

    def check(user, quest)
      goal(quest.goal_key).check(user, quest)
    end

    def goal(key)
      { "code_days" => CodeDays, "streak_days" => StreakDays, "ship_project" => ShipProject,
        "link_hackatime" => LinkHackatime, "add_project" => AddProject }.fetch(key.to_s)
    end

    # The local dates of the quest's week that reached the 15-minute bar, each with the moment it first did.
    # Pure: `entries` are [local_date, seconds, recorded_at] rows in the order they were recorded.
    def qualifying_days(entries, threshold)
      running = Hash.new(0)
      reached = {}
      entries.each do |date, seconds, recorded_at|
        running[date] += seconds
        reached[date] ||= recorded_at if running[date] >= threshold
        reached.delete(date) if running[date] < threshold && reached.key?(date)
      end
      reached.sort.to_h
    end

    def day_entries(user, quest)
      Hours::Totals.counted_for(user, quest.starts_on..quest.ends_on).order(:recorded_at, :id).pluck(:local_date, :seconds, :recorded_at)
    end

    def threshold = Game::Config.current.quick_seconds

    # The instants [from, to) covering the quest's local dates in the user's zone.
    def instants(user, quest)
      zone = Hours::Days.zone(user.time_zone)
      [ zone.local(quest.starts_on.year, quest.starts_on.month, quest.starts_on.day),
        zone.local((quest.ends_on + 1).year, (quest.ends_on + 1).month, (quest.ends_on + 1).day) ]
    end

    # Code on `target` different days (each at least 15 minutes). Complete at the moment the target-th day reached the bar.
    module CodeDays
      module_function

      def check(user, quest)
        target = quest.target
        days = Goals.qualifying_days(Goals.day_entries(user, quest), Goals.threshold)
        moments = days.values.sort
        Progress.new(current: [ days.size, target ].min, target: target, completed_at: (moments[target - 1] if moments.size >= target))
      end
    end

    # Code at least 15 minutes on `target` consecutive local days, all inside the week. Complete at the earliest
    # moment any such run was whole (the latest "first reached" moment of the days in it).
    module StreakDays
      module_function

      def check(user, quest)
        target = quest.target
        days = Goals.qualifying_days(Goals.day_entries(user, quest), Goals.threshold)
        dates = days.keys
        longest = runs(dates).map(&:size).max.to_i
        finishes = runs(dates).flat_map do |run|
          run.each_cons(target).map { |window| window.map { |date| days.fetch(date) }.max } if run.size >= target
        end.compact
        Progress.new(current: [ longest, target ].min, target: target, completed_at: finishes.min)
      end

      # Consecutive-date runs of a sorted list of dates.
      def runs(dates)
        dates.slice_when { |previous, date| date != previous + 1 }.to_a
      end
    end

    # Send a ship in for review (submitted, or already approved) during the week. A withdrawn or rejected one does not count.
    module ShipProject
      module_function

      def check(user, quest)
        from, to = Goals.instants(user, quest)
        at = Ship.where(user_id: user.id, status: Ship::WINDOW_STATUSES, submitted_at: from...to).minimum(:submitted_at)
        Progress.new(current: at ? 1 : 0, target: 1, completed_at: at)
      end
    end

    # Link a Hackatime project to one of the user's projects during the week.
    module LinkHackatime
      module_function

      def check(user, quest)
        from, to = Goals.instants(user, quest)
        at = HackatimeLink.where(user_id: user.id, created_at: from...to).minimum(:created_at)
        Progress.new(current: at ? 1 : 0, target: 1, completed_at: at)
      end
    end

    # Add a project during the week.
    module AddProject
      module_function

      def check(user, quest)
        from, to = Goals.instants(user, quest)
        at = Project.where(user_id: user.id, created_at: from...to).minimum(:created_at)
        Progress.new(current: at ? 1 : 0, target: 1, completed_at: at)
      end
    end
  end
end
