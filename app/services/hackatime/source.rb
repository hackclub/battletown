module Hackatime
  # The seam between Hackatime and the hours ledger. A source is any object that answers
  #
  #   daily_seconds(user:, from:, to:) -> [Hackatime::DaySeconds]
  #
  # where `from` and `to` are inclusive local dates (nil means unbounded) and the result holds the reported TOTAL per
  # day and project (not deltas). Sources only report; Hours::Sync decides what to credit. Implementations: NullSource
  # (the default: reports nothing), CsvSource (an operator-supplied file) and HttpSource (live Hackatime for users who
  # linked their account by OAuth; identity is the Hackatime user id, tokens live encrypted in hackatime_connections,
  # see docs/HACKATIME.md). Hackatime.source picks the default from `hours_source` in config/game.yml.
  module Source
    def daily_seconds(user:, from: nil, to: nil)
      raise NotImplementedError, "#{self.class} must implement daily_seconds(user:, from:, to:)"
    end
  end
end
