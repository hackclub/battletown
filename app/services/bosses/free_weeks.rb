module Bosses
  # Which boss weeks staff can still add. A boss week starts on a Friday; a week is free when no existing boss overlaps it. Pure
  # (it reads only the bosses it is given), so the admin pages load the list once, without picture bytes.
  #
  #   weeks = Bosses::FreeWeeks.new(Boss.without_art_content.chronological.to_a, today: Date.current)
  #   weeks.options        # the next 10 free Fridays, to offer in the form
  #   weeks.default        # the Friday after the latest boss (or the next Friday when it is already past)
  #   weeks.missing_next   # the first Friday with no boss, from today on, when it is at most 8 days away, else nil
  #   weeks.missing_current # the Friday a running week began on when it has no boss and can no longer be added, else nil
  class FreeWeeks
    OPTIONS = 10
    NOTICE_DAYS = 8
    # A safety stop for the search: ten free Fridays are always found within this many weeks of any real list.
    SEARCH_WEEKS = 520

    def initialize(bosses, today:)
      @bosses = bosses
      @today = today
    end

    def options
      @options ||= upcoming_fridays.lazy.select { |friday| free?(friday) }.first(OPTIONS)
    end

    def default
      @default ||= options.find { |friday| friday >= after_latest } || options.first
    end

    # The first Friday with no boss on or after today (a gap before a later boss counts), when it is close enough to matter.
    def missing_next
      week = options.first
      week if week && week <= @today + NOTICE_DAYS
    end

    # The week running today when it began on a Friday already gone and has no boss: the form only offers future Fridays, so
    # it can no longer be added here and the page says so.
    def missing_current
      week = @today - ((@today.wday - 5) % 7)
      week if week < @today && free?(week)
    end

    def free?(friday)
      @bosses.none? { |boss| boss.starts_on <= friday + 6 && boss.ends_on >= friday }
    end

    private

    # The Friday on or after today.
    def next_friday = @today + ((5 - @today.wday) % 7)

    def after_latest
      latest = @bosses.map(&:ends_on).max
      latest ? latest + 1 : next_friday
    end

    def upcoming_fridays = (0...SEARCH_WEEKS).lazy.map { |week| next_friday + (week * 7) }
  end
end
