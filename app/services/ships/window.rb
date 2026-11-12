module Ships
  # The coded time a project could ship right now, read from the hours ledger.
  #
  # It is the net seconds of the user's ledger entries whose `hackatime_project` is one of the Hackatime projects
  # linked to the project, on local dates AFTER the window end of the project's previous ship that still counts
  # (submitted or approved: a rejected or withdrawn ship gives its window back), or from the beginning when there is
  # none, and never before the user's first counted date (`Hours::Days.first_counted_date`: hours coded before signing
  # up earn no coins). Entries without a Hackatime project (manual credits) and other projects' time are never included. Dates
  # are the frozen local dates on the entries, so time zones and daylight saving are already settled there.
  #
  # `hours_since_previous_ship_before_window` is the hours already counted toward the 6 hour deflation threshold
  # before this window starts. The window is everything since the previous ship, so it is always 0 here; it is returned
  # so the value Coins::ApproveShip needs has one obvious owner.
  #
  # Note: whole local dates are the unit, so time coded on the previous ship's last date AFTER it was submitted
  # (the same day) belongs to no ship.
  module Window
    Result = Data.define(:seconds, :start_date, :end_date, :hours_since_previous_ship_before_window, :seconds_by_date) do
      def empty? = seconds.zero?
      def hours = seconds / 3600.0
    end

    module_function

    def call(project)
      names = project.hackatime_links.pluck(:hackatime_project)
      return build({}) if names.empty?

      after = project.ships.where(status: Ship::WINDOW_STATUSES).maximum(:window_end_date)
      entries = HourEntry.where(user_id: project.user_id, hackatime_project: names, local_date: Hours::Days.first_counted_date(project.user)..)
      entries = entries.where("local_date > ?", after) if after
      by_date = entries.group(:local_date).sum(:seconds).select { |_, seconds| seconds.positive? }.sort.to_h
      build(by_date)
    end

    def build(by_date)
      Result.new(seconds: by_date.values.sum, start_date: by_date.keys.first, end_date: by_date.keys.last,
                 hours_since_previous_ship_before_window: 0, seconds_by_date: by_date.freeze)
    end
    private_class_method :build
  end
end
