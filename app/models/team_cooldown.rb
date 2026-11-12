# When a person last left a crew, so Teams::Crew can hold them to the leave cooldown before they join another. One row per
# user, deleted with the user by the database (ON DELETE CASCADE).
class TeamCooldown < ApplicationRecord
  belongs_to :user

  validates :left_at, presence: true

  def ends_at(config = Teams::Config.current) = left_at + config.leave_cooldown_seconds
end
