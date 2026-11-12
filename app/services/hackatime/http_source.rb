module Hackatime
  # Live hours source: implements the source duck type `daily_seconds(user:, from:, to:)` returning
  # Hackatime::DaySeconds(date:, seconds:, project:) rows (one per local day and project with time in it).
  #
  # Hackatime's OAuth-readable API has no per-day, per-project endpoint, so this asks once per local day for
  # GET /api/v1/authenticated/projects with start_date and end_date set to that day's local midnight bounds
  # (ISO 8601 with the user's UTC offset), which returns each project's seconds inside the window. Days are the
  # user's own: their `time_zone` decides when a day starts and what "today" is, so a 23 or 25 hour day around a
  # DST change is handled by the bounds, not by arithmetic here. The window of a date is frozen the first time it is
  # fetched (Hackatime::DayWindows), so changing time zone never counts the same time twice. See docs/HACKATIME.md.
  class HttpSource
    include Source

    MAX_DAYS = 62
    # A calendar day is at most 25 hours long (DST); anything larger from Hackatime is clamped as nonsense.
    MAX_DAY_SECONDS = 25.hours.to_i
    # The window is inclusive at both ends, so stop one millisecond short of the next midnight.
    END_MARGIN = Rational(1, 1000)

    def initialize(client_factory: ->(connection) { Client.new(connection) })
      @client_factory = client_factory
    end

    # Raises Hackatime::Client::AuthError (user must reconnect) or RetryableError (try again later); a user who
    # never connected, or must reconnect, simply has no rows.
    #
    # `from` / `to` are inclusive local dates. nil means unbounded, which here means: `to` is the user's today and
    # `from` is MAX_DAYS - 1 days before `to` (a live API cannot be asked for "everything").
    def daily_seconds(user:, from: nil, to: nil)
      connection = user.hackatime_connection
      return [] if connection.nil? || connection.needs_reconnect?

      zone = ActiveSupport::TimeZone[user.time_zone.to_s] || ActiveSupport::TimeZone["UTC"]
      today = zone.today
      last = [ to&.to_date || today, today ].min
      first = from&.to_date || (last - (MAX_DAYS - 1))
      return [] if last < first
      raise ArgumentError, "range too long (max #{MAX_DAYS} days)" if (last - first).to_i >= MAX_DAYS

      # Up to tomorrow (the latest date the ledger accepts) when the range runs to today: after a move west, time
      # coded now can belong to a date frozen in the old zone that is still ahead of the new zone's today.
      ahead_until = today + 1 if to.nil? || to.to_date >= today
      windows = DayWindows.new(user: user, hackatime_uid: connection.hackatime_uid, zone: zone).resolve(first, last, ahead_until: ahead_until)
      client = @client_factory.call(connection)
      rows = windows.reject(&:empty?).flat_map { |window| day_rows(client, zone, window) }
      connection.record_sync!
      rows
    end

    private

    def day_rows(client, zone, window)
      starts = window.starts_at.in_time_zone(zone)
      ends = window.ends_at.in_time_zone(zone) - END_MARGIN
      body = client.get_json("/api/v1/authenticated/projects",
        start_date: starts.iso8601(3), end_date: ends.iso8601(3), include_archived: "true")

      Array(body["projects"]).filter_map do |project|
        next unless project.is_a?(Hash)

        name = project["name"].to_s.strip
        seconds = project["total_seconds"].to_f.floor.clamp(0, MAX_DAY_SECONDS)
        next if name.empty? || seconds.zero?

        DaySeconds.new(date: window.local_date, seconds: seconds, project: name.first(200))
      end
    end
  end
end
