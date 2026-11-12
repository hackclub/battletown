# One person's choice for one kind of message on one channel (Slack DM or email). A row exists only once someone
# changed a switch; no row means the default, which is on (see Notifications::Preferences). Deleted with the user
# (ON DELETE CASCADE).
class NotificationPreference < ApplicationRecord
  belongs_to :user

  validates :kind, inclusion: { in: Notification::KINDS }
  validates :enabled, inclusion: { in: [ true, false ] }
  validates :channel, inclusion: { in: Notification::CHANNELS }
  validates :kind, uniqueness: { scope: %i[user_id channel] }
end
