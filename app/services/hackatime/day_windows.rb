module Hackatime
  # Decides which UTC window each local date stands for when Hackatime time is fetched, and freezes it
  # (HackatimeDayWindow), so the same coded instant is never credited to two dates. See docs/HACKATIME.md,
  # "Days and time zones".
  #
  # - A date that already has a window keeps it forever, whatever the user's time zone is now.
  # - A new date runs from its local midnight to the next one in the user's CURRENT zone, except that:
  #   - it starts no earlier than the end of any window of an earlier date (a move east would otherwise overlap);
  #   - when the day before has a window, it starts exactly where that one ended (a move west would otherwise leave
  #     a gap between the two, and that time would be lost);
  #   - it ends no later than the start of any window of a later date;
  #   - it starts no earlier than the end of any window another Battletown account fetched from the same Hackatime
  #     account (a Hackatime account moved to a second Battletown account does not bring its hours again).
  #   If nothing is left the window is empty: it is still written, so the next date chains from it, but never fetched.
  #
  # A window is only ever fetched with the Hackatime account it is labelled with (HttpSource skips the others), so the
  # label is always the account the time came from and the cross-account rule above can key on it, whichever
  # Battletown account the window belongs to.
  #
  # So a time zone change costs nothing in the common case. What it can cost is the rest of a date that a second
  # Battletown account already covered for the same Hackatime account; and switching Hackatime accounts costs the
  # dates already frozen under the old one (at most the back-fill window, today and tomorrow).
  class DayWindows
    def initialize(user:, hackatime_uid:, zone:)
      @user = user
      @uid = hackatime_uid.to_s
      @zone = zone
    end

    # Frozen windows for every date in first..last (writing the missing ones), then any already-frozen window of a
    # later date up to `ahead_until` that has started by `now` (after a move west, the old zone's dates run ahead of
    # the new zone's today). Ordered by date; empty windows included.
    def resolve(first, last, now: Time.current, ahead_until: nil)
      windows = own.where(local_date: (first - 1)..).index_by(&:local_date)
      reach = own.where(local_date: ...first).maximum(:ends_at)
      others = HackatimeDayWindow.where(hackatime_uid: @uid).where.not(user_id: @user.id).maximum(:ends_at)

      fresh = (first..last).filter_map do |date|
        window = windows[date] ||= build(date, windows, reach, others)
        reach = [ reach, window.ends_at ].compact.max
        window if window.new_record?
      end
      persist(fresh)

      ahead = ahead_until && ahead_until > last ? own.where(local_date: (last + 1)..ahead_until).where(starts_at: ..now).to_a : []
      own.where(local_date: first..last).order(:local_date).to_a + ahead.sort_by(&:local_date)
    end

    private

    def own = HackatimeDayWindow.where(user_id: @user.id)

    def build(date, windows, reach, others)
      starts = windows[date - 1]&.ends_at || midnight(date)
      starts = [ starts, reach, others ].compact.max
      later = windows.select { |other_date, window| other_date > date && !window.empty? }.values.map(&:starts_at).min
      ends = [ midnight(date + 1), later ].compact.min
      HackatimeDayWindow.new(user: @user, local_date: date, starts_at: starts, ends_at: [ ends, starts ].max, hackatime_uid: @uid)
    end

    def midnight(date) = @zone.local(date.year, date.month, date.day)

    # Two syncs for one user at once: the first window written for a date wins, and both return that one.
    def persist(fresh)
      return if fresh.empty?

      rows = fresh.map { |window| window.attributes.slice("user_id", "local_date", "starts_at", "ends_at", "hackatime_uid") }
      HackatimeDayWindow.insert_all(rows, unique_by: %i[user_id local_date])
    end
  end
end
