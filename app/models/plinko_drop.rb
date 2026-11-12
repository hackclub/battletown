# One ball dropped in Plinko (docs/CONTRACT.md, "Plinko"). The slot and points are chosen by the server from `seed`
# (Plinko::Board) and never change; rows are only ever created by Plinko::Drop. Holds no personal data beyond the user
# reference and is deleted with the user by the database (ON DELETE CASCADE). Plinko never touches coins.
class PlinkoDrop < ApplicationRecord
  KEY_FORMAT = /\A[A-Za-z0-9_-]{8,64}\z/

  belongs_to :user

  validates :slot, :points, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :seed, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :dropped_at, :local_date, presence: true
  validates :idempotency_key, format: { with: KEY_FORMAT }

  def readonly? = persisted? || super

  # The route the ball took: an array of 0 (left) and 1 (right), one per row of pegs, rebuilt from the seed.
  def path(board: Plinko::Board.current) = board.walk(seed)
end
