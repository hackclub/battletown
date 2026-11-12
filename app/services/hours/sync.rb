module Hours
  # Turns what Hackatime reports into ledger credits.
  #
  #   Hours::Sync.call(user)                                   # ask Hackatime.source for the user's recent days
  #   Hours::Sync.call(user, source: Hackatime::CsvSource.new(path), from: nil, to: nil)   # a whole file
  #   Hours::Sync.call(day_seconds_rows, user: user)           # rows you already have ([Hackatime::DaySeconds])
  #
  # For every reported (date, project) total it credits only the DIFFERENCE between that total and what Hackatime
  # time is already credited for that date and project (source "hackatime" rows only; manual credits and adjustments
  # are separate), using the idempotency key `hackatime:<date>:<project>:<reported_total>`, so running it again with
  # the same report changes nothing. A reported total lower than what is credited is never clawed back: it is skipped
  # and counted (logged by count only). Days the ledger refuses (outside the backfill window) are counted as rejected.
  # `from:` / `to:` are inclusive local dates; the default `:window` is the backfill window ending at the user's local
  # today, nil means unbounded (used for a file import).
  class Sync
    Summary = Data.define(:credited_seconds, :credited_days, :unchanged_days, :skipped_negative, :rejected, :capped) do
      def self.empty = new(0, 0, 0, 0, 0, 0)

      def +(other) = Summary.new(*members.map { |member| public_send(member) + other.public_send(member) })
    end

    CREATED_BY = "hackatime:sync".freeze
    KEY_PROJECT_LIMIT = 60

    def self.call(user_or_rows, user: nil, source: Hackatime.source, from: :window, to: :window, config: Config.current)
      new(config: config).call(user_or_rows, user: user, source: source, from: from, to: to)
    end

    def self.key_for(date:, project:, reported:)
      # A long project name is replaced by a digest so the key always fits the 120 character column.
      part = project.to_s.length <= KEY_PROJECT_LIMIT ? project.to_s : "sha256-#{Digest::SHA256.hexdigest(project)[0, 24]}"
      "hackatime:#{date.iso8601}:#{part}:#{reported}"
    end

    def initialize(config:)
      @config = config
    end

    def call(user_or_rows, user:, source:, from:, to:)
      if user_or_rows.is_a?(User)
        user = user_or_rows
        today = Days.today(user.time_zone)
        from = today - @config.max_backfill_days if from == :window
        to = today if to == :window
        rows = source.daily_seconds(user: user, from: from, to: to)
      else
        raise ArgumentError, "pass user: with rows" unless user.is_a?(User)

        rows = Array(user_or_rows)
      end

      # One boss defeat check for the whole user, not one per credited day (Bosses::CheckDefeat.batched).
      summary = Bosses::CheckDefeat.batched { rows.reduce(Summary.empty) { |total, day| total + sync_day(user, day) } }
      Rails.logger.warn("hours.sync skipped_negative=#{summary.skipped_negative}") if summary.skipped_negative.positive?
      summary
    end

    private

    def sync_day(user, day)
      project = day.project.presence
      key = self.class.key_for(date: day.date, project: project, reported: day.seconds)
      user.with_lock do
        credited = HourEntry.where(user_id: user.id, source: "hackatime", local_date: day.date, hackatime_project: project).sum(:seconds)
        delta = day.seconds - credited
        next change(unchanged_days: 1) if delta.zero?
        next change(skipped_negative: 1) if delta.negative?

        result = Credit.call(user: user, seconds: delta, source: "hackatime", idempotency_key: key, local_date: day.date,
                             hackatime_project: project, created_by: CREATED_BY, config: @config)
        if result.created? then change(credited_seconds: result.credited_seconds, credited_days: 1)
        elsif result.capped? then change(capped: 1)
        else change(unchanged_days: 1)
        end
      end
    rescue Credit::Rejected
      change(rejected: 1)
    end

    def change(**counts) = Summary.empty.with(**counts)
  end
end
