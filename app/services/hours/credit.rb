module Hours
  # The only way to write the hours ledger.
  #
  #   Hours::Credit.call(user: user, seconds: 1800, source: "manual", idempotency_key: "manual:abc",
  #                      at: Time.current, note: "Workshop", created_by: "rake:credit")
  #
  # - Idempotent: a second call with the same (user, idempotency_key) returns the row that already exists
  #   (`result.duplicate?`), whatever the other arguments say.
  # - Serialised per user: the work runs inside `user.with_lock`, so two credits for one user never interleave and
  #   the daily cap cannot be beaten by racing requests.
  # - Daily cap: positive seconds are clamped so the user's total for one local date never passes
  #   `Hours::Config#daily_cap_seconds`. If the day is already full nothing is written (`result.capped?`, entry nil).
  #   Adjustments are operator corrections and are never clamped.
  # - Backfill window: a date older than `max_backfill_days` before the user's local today is rejected, unless the
  #   source is `adjustment`. A date later than the user's local tomorrow is rejected too.
  # - Pass either `local_date:` (a Date, used as is) or `at:` (an instant; the local date is derived from the user's
  #   time zone, UTC when blank or unknown, and frozen on the row).
  #
  # Raises Hours::Credit::Rejected for input that can never be credited (callers that loop over many rows count it).
  class Credit
    class Rejected < StandardError; end

    # status: :created, :clamped (created, but fewer seconds than requested), :duplicate, or :capped (nothing written).
    Result = Data.define(:entry, :status, :requested_seconds) do
      def duplicate? = status == :duplicate
      def capped? = status == :capped
      def clamped? = status == :clamped
      def created? = status == :created || status == :clamped
      def credited_seconds = entry && !duplicate? ? entry.seconds : 0
    end

    def self.call(**args) = new(**args).call

    def initialize(user:, seconds:, source:, idempotency_key:, local_date: nil, at: nil, hackatime_project: nil,
                   note: nil, created_by: nil, config: Config.current)
      @user = user
      @seconds = seconds
      @source = source.to_s
      @key = idempotency_key.to_s
      @local_date = local_date
      @at = at
      @project = hackatime_project.presence
      @note = note.presence
      @created_by = created_by.presence
      @config = config
      validate_arguments!
    end

    def call
      @user.with_lock do
        existing = HourEntry.find_by(user_id: @user.id, idempotency_key: @key)
        next Result.new(entry: existing, status: :duplicate, requested_seconds: @seconds) if existing

        date = resolve_date
        check_window!(date)
        credited = clamped_seconds(date)
        next Result.new(entry: nil, status: :capped, requested_seconds: @seconds) if credited.nil?

        insert(date, credited)
      end
    end

    private

    def validate_arguments!
      raise Rejected, "user must be saved" unless @user.is_a?(User) && @user.persisted?
      raise Rejected, "unknown source" unless HourEntry::SOURCES.include?(@source)
      raise Rejected, "idempotency_key must be 1 to 120 characters" unless (1..120).cover?(@key.length)
      raise Rejected, "seconds must be a non-zero integer within one day" unless @seconds.is_a?(Integer) && @seconds != 0 && @seconds.abs <= HourEntry::MAX_SECONDS
      raise Rejected, "seconds must be positive unless the source is an adjustment" if @seconds.negative? && !adjustment?
      raise Rejected, "a note is required unless the source is hackatime" if @note.nil? && @source != "hackatime"
      raise Rejected, "give local_date or at, not both and not neither" if @local_date.nil? == @at.nil?
      raise Rejected, "local_date must be a Date" unless @local_date.nil? || @local_date.is_a?(Date)
      raise Rejected, "at must be a Time" unless @at.nil? || @at.is_a?(Time) || @at.is_a?(DateTime)
    end

    def adjustment? = @source == "adjustment"

    def resolve_date = @local_date || Days.local_date(@at, @user.time_zone)

    def check_window!(date)
      today = Days.today(@user.time_zone)
      raise Rejected, "local_date is older than #{@config.max_backfill_days} days" if !adjustment? && date < today - @config.max_backfill_days
      raise Rejected, "local_date is in the future" if date > today + 1
    end

    # Positive credits only: never let the user's total for the date pass the daily cap. nil means the day is full.
    def clamped_seconds(date)
      return @seconds if adjustment?

      room = @config.daily_cap_seconds - HourEntry.where(user_id: @user.id, local_date: date).sum(:seconds)
      room.positive? ? [ @seconds, room ].min : nil
    end

    def insert(date, credited)
      entry = HourEntry.transaction(requires_new: true) do
        HourEntry.create!(user: @user, local_date: date, seconds: credited, source: @source, idempotency_key: @key,
                          hackatime_project: @project, note: @note, created_by: @created_by)
      end
      Result.new(entry: entry, status: credited == @seconds ? :created : :clamped, requested_seconds: @seconds)
    rescue ActiveRecord::RecordNotUnique
      # Only reachable if something wrote this key without taking the user lock.
      Result.new(entry: HourEntry.find_by!(user_id: @user.id, idempotency_key: @key), status: :duplicate, requested_seconds: @seconds)
    end
  end
end
