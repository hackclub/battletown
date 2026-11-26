module Analytics
  # The coarse buckets event properties use (the values are the enums in config/analytics.yml), so a call site passes a number and never a
  # precise figure: `Analytics.track(:ship_approved, user: u, hours_bucket: Analytics::Buckets.hours(seconds), nth: Analytics::Buckets.nth(count))`.
  module Buckets
    HOUR = 3600

    class << self
      # lt1, 1-2, 2-5, 5-10, 10plus (seconds in; a bucket's lower bound is included).
      def hours(seconds)
        hours = seconds.to_f / HOUR
        if hours < 1 then "lt1"
        elsif hours < 2 then "1-2"
        elsif hours < 5 then "2-5"
        elsif hours < 10 then "5-10"
        else "10plus"
        end
      end

      # 1, 2-3, 4-6, 7-13, 14plus (a length in days; below 1 counts as 1).
      def days(count)
        count = count.to_i
        if count <= 1 then "1"
        elsif count <= 3 then "2-3"
        elsif count <= 6 then "4-6"
        elsif count <= 13 then "7-13"
        else "14plus"
        end
      end

      # 1, 2, 3plus: which one this is for the person (the count INCLUDES this one).
      def nth(count)
        count = count.to_i
        count <= 1 ? "1" : (count == 2 ? "2" : "3plus")
      end

      # same_day, 1d, 2d, 3plus_d: how long something waited, by elapsed time (under 24 hours is the same day).
      def waited(from, to = Time.current)
        days = ((to - from) / 1.day).floor
        if days <= 0 then "same_day"
        elsif days == 1 then "1d"
        elsif days == 2 then "2d"
        else "3plus_d"
        end
      end
    end
  end
end
