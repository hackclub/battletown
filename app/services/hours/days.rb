module Hours
  # Local-date maths for the ledger. A "day" is the user's local calendar date in `users.time_zone` (an
  # ActiveSupport zone name or an IANA id), falling back to UTC when the zone is blank or unknown. Always go through
  # the zone's calendar (`in_time_zone(...).to_date`, `zone.local(...)`), never add 24 hours: a day is 23 or 25 hours
  # long when the clocks change.
  module Days
    module_function

    def zone(name) = (name.present? && Time.find_zone(name)) || Time.find_zone!("UTC")

    # The local date of `instant` for a user (or zone name).
    def local_date(instant, user_or_zone)
      instant.in_time_zone(zone(zone_name(user_or_zone))).to_date
    end

    # The user's current local date.
    def today(user_or_zone, now: Time.current) = local_date(now, user_or_zone)

    def zone_name(user_or_zone) = user_or_zone.respond_to?(:time_zone) ? user_or_zone.time_zone : user_or_zone
  end
end
