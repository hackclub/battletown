# The UTC window [starts_at, ends_at) one local date stood for when Hackatime time was first fetched for it, and the
# Hackatime account it was fetched from. Written once by Hackatime::DayWindows and never changed, so a later time zone
# change cannot make two dates cover the same instant (docs/HACKATIME.md, "Days and time zones"). An empty window
# (starts_at == ends_at) means the date had nothing left to cover. Holds no personal data beyond the user reference
# and the Hackatime user id; deleted with the user by the database (ON DELETE CASCADE).
class HackatimeDayWindow < ApplicationRecord
  belongs_to :user

  validates :local_date, :starts_at, :ends_at, presence: true
  validates :hackatime_uid, presence: true, length: { maximum: 40 }

  def empty? = ends_at <= starts_at
end
