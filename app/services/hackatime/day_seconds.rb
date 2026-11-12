module Hackatime
  # One day of coded time reported by Hackatime: the user's local date, the TOTAL seconds for that day (not a delta)
  # and the Hackatime project name (nil when the source does not split by project). Nothing else about the work.
  DaySeconds = Data.define(:date, :seconds, :project) do
    def initialize(date:, seconds:, project: nil) = super
  end
end
