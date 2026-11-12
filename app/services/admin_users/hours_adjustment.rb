module AdminUsers
  # Add or take off coded time for one local date, as a new `adjustment` row in the hours ledger (Hours::Credit). The earlier
  # rows are never edited. Bounded to config `admin_users.max_adjust_minutes` (24 hours at most) a time, dated from the person's
  # first counted day to their tomorrow, and a day can never be taken below zero or pushed past 24 hours. Hours::Credit does not
  # clamp adjustments to the 12-hour daily cap (they are operator corrections), so the confirm page warns when one goes past it.
  # Days that already settled into a streak result are NOT recomputed: only boss damage and later totals move.
  class HoursAdjustment < Adjustment
    attribute :date, :string
    attribute :minutes, :string

    validate :date_is_usable
    validate :minutes_are_usable
    validate :day_stays_within_bounds

    def local_date
      return @local_date if defined?(@local_date)

      @local_date = begin
        text = date.to_s
        text.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(text) : nil
      rescue ArgumentError
        nil
      end
    end

    def whole_minutes = minutes.to_s.match?(/\A\d{1,5}\z/) ? minutes.to_i : nil

    def seconds = (whole_minutes || 0) * 60 * sign

    # Seconds the ledger holds for that date now, and after this adjustment.
    def day_before = local_date ? HourEntry.where(user_id: user.id, local_date: local_date).sum(:seconds) : 0

    def day_after = day_before + seconds

    def past_daily_cap? = day_after > Hours::Config.current.daily_cap_seconds

    def settled_day? = local_date.present? && DailyResult.exists?(user_id: user.id, local_date: local_date)

    def first_date = Hours::Days.first_counted_date(user)

    def last_date = Hours::Days.today(user.time_zone) + 1

    private

    def existing_record = HourEntry.find_by(user_id: user.id, idempotency_key: idempotency_key)

    def write!
      result = Hours::Credit.call(user: user, seconds: seconds, source: "adjustment", idempotency_key: idempotency_key,
                                  local_date: local_date, note: reason, created_by: created_by)
      entry = result.entry
      AdminAudit.record!(actor: staff, action: "hours_adjusted", subject: user,
                         metadata: { local_date: local_date, seconds: seconds, reason: reason, entry_id: entry.id })
      entry
    rescue Hours::Credit::Rejected => error
      errors.add(:base, "The hours ledger refused this: #{error.message}.")
      raise Invalid, self
    end

    def date_is_usable
      if local_date.nil?
        errors.add(:date, "must be a date, like 2026-11-10")
      elsif local_date < first_date
        errors.add(:date, "is before the first day that counts for this person (#{first_date.iso8601}), so it would change nothing")
      elsif local_date > last_date
        errors.add(:date, "can't be later than tomorrow in their time zone (#{last_date.iso8601})")
      end
    end

    def minutes_are_usable
      max = Config.current.max_adjust_minutes
      return if whole_minutes&.between?(1, max)

      errors.add(:minutes, "must be a whole number from 1 to #{ActiveSupport::NumberHelper.number_to_delimited(max)}")
    end

    def day_stays_within_bounds
      return if local_date.nil? || whole_minutes.nil? || !DIRECTIONS.include?(direction)

      before = day_before
      if seconds.negative? && before + seconds < 0
        errors.add(:minutes, "is more than the #{before / 60} minutes recorded for that day, so it can't be taken off")
      elsif before + seconds > HourEntry::MAX_SECONDS
        errors.add(:minutes, "would put more than 24 hours on that day")
      end
    end
  end
end
