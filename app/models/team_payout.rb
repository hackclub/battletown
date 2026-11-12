# The record that an approved ship was looked at for the crew bonus (even when it paid 0), written by Teams::PayShip in the
# same transaction as the ledger row. Unique per ship, so a ship is paid at most once and never later with different data.
# `coins` is what was credited (the ledger row `team_bonus:ship:<id>` holds the coins themselves). Deleted with the user or
# the ship by the database; the crew reference is nulled when a crew is dissolved.
class TeamPayout < ApplicationRecord
  belongs_to :user
  belongs_to :ship
  belongs_to :team, optional: true

  validates :coins, :matched_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :ship_id, uniqueness: true
end
