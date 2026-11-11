module Notifications
  # No messages inside the user's local quiet window (config: quiet_hours_start .. quiet_hours_end, which may cross
  # midnight, default 22:00 to 07:00).
  module QuietHours
    module_function

    # nil when `instant` is outside the window, otherwise the UTC instant the window ends in the user's zone.
    def deferral(instant, zone, config: Config.current)
      start_minute = config.quiet_start
      end_minute = config.quiet_end
      return nil if start_minute == end_minute

      local = instant.in_time_zone(zone)
      minute = local.hour * 60 + local.min
      crosses_midnight = start_minute > end_minute
      quiet = crosses_midnight ? (minute >= start_minute || minute < end_minute) : (minute >= start_minute && minute < end_minute)
      return nil unless quiet

      date = local.to_date
      date += 1 if crosses_midnight && minute >= start_minute
      Reminders.instant_for(zone, date, end_minute / 60, end_minute % 60)
    end
  end
end
