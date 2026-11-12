# One person in one crew. Unique per user (one crew at a time). Deleted with the user or the crew by the database
# (ON DELETE CASCADE); write through Teams::Crew.
class TeamMembership < ApplicationRecord
  belongs_to :team
  belongs_to :user

  validates :joined_at, presence: true
  validates :user_id, uniqueness: true
end
