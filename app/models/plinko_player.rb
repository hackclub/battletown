# A player's leaderboard setting and generated nickname. The nickname comes only from the word lists in
# config/game.yml (Plinko::Nicknames), never from a real name. `leaderboard_opt_in` is false until the player turns it
# on; only opted-in players are ever listed, and only by nickname. Deleted with the user (ON DELETE CASCADE).
class PlinkoPlayer < ApplicationRecord
  belongs_to :user

  validates :nickname, presence: true, length: { maximum: 40 }, uniqueness: { case_sensitive: false }
end
