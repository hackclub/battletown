# One person's choice for one kind of Slack message. A row exists only once someone changed a switch; no row means
# the default, which is on (see Notifications::Preferences). Deleted with the user (ON DELETE CASCADE).
class NotificationPreference < ApplicationRecord
  belongs_to :user

  validates :kind, inclusion: { in: Notification::KINDS }
  validates :enabled, inclusion: { in: [ true, false ] }
  validates :kind, uniqueness: { scope: :user_id }
end
