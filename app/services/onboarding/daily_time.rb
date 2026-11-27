module Onboarding
  # The time a day a prize takes to earn by the end of the program (config/game.yml `onboarding.program_ends_on`, or the
  # ONBOARDING_PROGRAM_ENDS_ON environment variable for a local look). Nothing here invents an end date: with none set, or one that
  # has passed, the time-a-day methods count against the stand-in or return nil and callers keep the total-hours wording.
  module DailyTime
    # The minutes a day the pace question really offers (OnboardingsHelper::ONBOARDING_PACES is this list). Every "about N minutes a day" a person
    # reads before that question rounds UP to one of these, so each figure shown is one they can pick; a need above the last one is not offered.
    PACES = [ 30, 60, 120, 180 ].freeze

    module_function

    def ends_on
      raw = ENV["ONBOARDING_PROGRAM_ENDS_ON"].presence || Rails.application.config_for(:game).dig(:onboarding, :program_ends_on).presence
      raw.is_a?(Date) ? raw : Date.iso8601(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Today through the end date, inclusive, every day of the week, in the app's zone. Zero or less once the date has passed.
    def days_left(today: Time.zone.today, ends_on: self.ends_on)
      (ends_on - today).to_i + 1 if ends_on
    end

    # The days a prize card counts against: the real days left, else the stand-in length from today (config onboarding.program_length_stand_in_days)
    # while no real end date is set. Nil once a real date has passed.
    def card_days(today: Time.zone.today, ends_on: self.ends_on)
      return days_left(today: today, ends_on: ends_on) if ends_on

      Rails.application.config_for(:game).dig(:onboarding, :program_length_stand_in_days).to_i.then { |days| days if days.positive? }
    end

    # True when the end date is real (set), false while the stand-in is used.
    def real_date? = ends_on.present?

    # Minutes a day, rounded UP to the nearest real pace choice (PACES); nil for a past date or more than the biggest choice a day (against the stand-in length when no date is set).
    def minutes_a_day(hours, today: Time.zone.today, ends_on: self.ends_on)
      minutes_over(hours, card_days(today: today, ends_on: ends_on))
    end

    # The same for any number of days: the minutes a day that earn `hours` in `days`, rounded up to a pace choice; nil over the biggest.
    def minutes_over(hours, days)
      return unless days&.positive? && hours.to_f.positive?

      raw = (hours.to_r * 60 / days).ceil
      PACES.find { |pace| raw <= pace }
    end

    # The paces the pace step offers for a prize: only those that finish by the end of the program. When none does, the biggest alone.
    def offered_paces(hours, today: Time.zone.today, ends_on: self.ends_on)
      return PACES unless hours.to_f.positive?

      fits = PACES.select { |minutes| reachable?(hours, minutes, today: today, ends_on: ends_on) }
      fits.presence || [ PACES.max ]
    end

    # True when even the biggest pace misses the end of the program.
    def none_in_time?(hours, today: Time.zone.today, ends_on: self.ends_on)
      hours.to_f.positive? && !reachable?(hours, PACES.max, today: today, ends_on: ends_on)
    end

    # "about 30 minutes a day", "about 1.5 hours a day", "about 2 hours a day".
    def text(minutes)
      return unless minutes

      amount = if minutes < 60 then "#{minutes} minutes"
      elsif minutes == 60 then "1 hour"
      elsif (minutes % 60).zero? then "#{minutes / 60} hours"
      else "#{minutes / 60.0} hours"
      end
      "about #{amount} a day"
    end

    # Can `minutes` a day earn a prize of `hours` by the end of the program? The end date when one is set, else the stand-in length (card_days).
    # True only when there is no length at all.
    def reachable?(hours, minutes, today: Time.zone.today, ends_on: self.ends_on)
      days = card_days(today: today, ends_on: ends_on)
      return true unless days
      return false unless days.positive?

      (hours.to_r * 60 / minutes).ceil <= days
    end
  end
end
