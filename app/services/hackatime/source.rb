module Hackatime
  # The seam between Hackatime and the hours ledger. A source is any object that answers
  #
  #   daily_seconds(user:, from:, to:) -> [Hackatime::DaySeconds]
  #
  # where `from` and `to` are inclusive local dates (nil means unbounded) and the result holds the reported TOTAL per
  # day and project (not deltas). Sources only report; Hours::Sync decides what to credit. Implementations: NullSource
  # (the default: reports nothing) and CsvSource (an operator-supplied file). There is deliberately NO live Hackatime
  # client yet: when API access exists, add an HttpSource here that matches users by `users.slack_id`, maps
  # Hackatime's day boundaries to the user's local date, never logs ids or tokens (read the token from the
  # environment, never the repo), and make Hackatime.source return it.
  module Source
    def daily_seconds(user:, from: nil, to: nil)
      raise NotImplementedError, "#{self.class} must implement daily_seconds(user:, from:, to:)"
    end
  end
end
