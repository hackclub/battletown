# Presence without a path or a time of day: one row per person per local day they used the site (the day by their own time zone, UTC when
# blank). Written at most once per person per day, by the controller concern; ON DELETE CASCADE from users.
class AnalyticsSiteDay < ApplicationRecord
  belongs_to :user

  # Records today for this person (idempotent). A cache guard keeps it to one cache read per request after the first of the day.
  def self.touch(user)
    day = local_day(user)
    Rails.cache.fetch("analytics/site_day/#{user.id}/#{day}", expires_in: 2.days) do
      insert_all([ { user_id: user.id, day: day } ], unique_by: %i[user_id day])
      true
    end
    nil
  end

  def self.local_day(user)
    (ActiveSupport::TimeZone[user.time_zone.to_s] || ActiveSupport::TimeZone["UTC"]).today
  end
end
