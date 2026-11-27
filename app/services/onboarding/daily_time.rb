module Onboarding
  # The time a day a prize takes to earn by the end of the program (config/game.yml `onboarding.program_ends_on`, or the
  # ONBOARDING_PROGRAM_ENDS_ON environment variable for a local look). Nothing here invents an end date: with none set, or one that
  # has passed, the time-a-day methods count against the stand-in or return nil and callers keep the total-hours wording.
  module DailyTime
    STEPS = [ 15, 30, 45, 60, 90 ].freeze # then whole hours
    MAX_MINUTES = 8 * 60

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

    # Minutes a day, rounded UP to a step (15, 30, 45, 60, 90, then whole hours); nil for a past date or more than 8 hours a day (against the stand-in length when no date is set).
    def minutes_a_day(hours, today: Time.zone.today, ends_on: self.ends_on)
      minutes_over(hours, card_days(today: today, ends_on: ends_on))
    end

    # The same for any number of days: the minutes a day that earn `hours` in `days`, rounded up to a step; nil over 8 hours a day.
    def minutes_over(hours, days)
      return unless days&.positive? && hours.to_f.positive?

      raw = (hours.to_r * 60 / days).ceil
      minutes = STEPS.find { |step| raw <= step } || (raw / 60.0).ceil * 60
      minutes unless minutes > MAX_MINUTES
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

    # Can `minutes` a day earn a prize of `hours` by the end date? True when there is no date.
    def reachable?(hours, minutes, today: Time.zone.today, ends_on: self.ends_on)
      days = days_left(today: today, ends_on: ends_on)
      return true unless days
      return false unless days.positive?

      (hours.to_r * 60 / minutes).ceil <= days
    end
  end
end
