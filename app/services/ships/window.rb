module Ships
  # The coded time a project could ship right now, read from the hours ledger.
  #
  # It is the net seconds of the user's ledger entries whose `hackatime_project` is one of the Hackatime projects
  # linked to the project, never before the user's first counted date (`Hours::Days.first_counted_date`: hours coded
  # before signing up earn no coins). Coverage belongs to the Hackatime project name, not to the project it is linked
  # to now: each name counts from the local date AFTER the window end of the user's last ship that still counts
  # (submitted or approved: a rejected or withdrawn ship gives its window back) and covered that name
  # (`ships.hackatime_projects`), whichever project that ship was on, or from the beginning when there is none. So
  # moving a link to another project never ships the same hours twice, and two projects never hold the same hours in
  # waiting ships. A ship saved before names were recorded (empty `hackatime_projects`) keeps the old rule: it covers
  # whatever is linked to its own project now. Entries without a Hackatime project (manual credits) and other
  # projects' time are never included; manual and adjustment entries that carry a name follow the same per-name rule.
  # Dates are the frozen local dates on the entries, so time zones and daylight saving are already settled there.
  #
  # `hackatime_projects` is every name linked to the project when the window was read: Ships::Submit freezes it on
  # the ship as the names that ship covers up to its `end_date`.
  #
  # `hours_since_previous_ship_before_window` is the hours already counted toward the 6 hour deflation threshold
  # before this window starts. The window is everything since the previous ship, so it is always 0 here; it is returned
  # so the value Coins::ApproveShip needs has one obvious owner.
  #
  # Note: whole local dates are the unit, so time coded on the previous ship's last date AFTER it was submitted
  # (the same day) belongs to no ship.
  module Window
    Result = Data.define(:seconds, :start_date, :end_date, :hours_since_previous_ship_before_window, :seconds_by_date,
                         :hackatime_projects) do
      def empty? = seconds.zero?
      def hours = seconds / 3600.0
    end

    module_function

    def call(project)
      names = project.hackatime_links.order(:hackatime_project).pluck(:hackatime_project)
      return build({}, names) if names.empty?

      covered = covered_until(project, names)
      entries = HourEntry.where(user_id: project.user_id, local_date: Hours::Days.first_counted_date(project.user)..)
      entries = names.map do |name|
        scope = entries.where(hackatime_project: name)
        covered[name] ? scope.where("local_date > ?", covered[name]) : scope
      end.reduce(:or)
      by_date = entries.group(:local_date).sum(:seconds).select { |_, seconds| seconds.positive? }.sort.to_h
      build(by_date, names)
    end

    # { name => the last local date a counting ship of this user already covers for it }; names never shipped are absent.
    def covered_until(project, names)
      ships = Ship.where(user_id: project.user_id, status: Ship::WINDOW_STATUSES)
      ships.pluck(:project_id, :hackatime_projects, :window_end_date).each_with_object({}) do |(project_id, ship_names, end_date), covered|
        ship_names = names if ship_names.empty? && project_id == project.id # saved before names were recorded
        (ship_names & names).each { |name| covered[name] = [ covered[name], end_date ].compact.max }
      end
    end

    def build(by_date, names)
      Result.new(seconds: by_date.values.sum, start_date: by_date.keys.first, end_date: by_date.keys.last,
                 hours_since_previous_ship_before_window: 0, seconds_by_date: by_date.freeze, hackatime_projects: names.freeze)
    end
    private_class_method :covered_until, :build
  end
end
