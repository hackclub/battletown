# A person's claim on one boss week's merch-track item (see MerchTrack, behind the Flipper flag `merch_track`): one per
# person per boss week (a unique index), no coins, no address (the team arranges delivery with the person on Slack).
# Created only through MerchTrack::Claim and changed only through MerchTrack::Fulfill / MerchTrack::Cancel, which hold
# the user lock. `item_name` is the name as it was when claimed, so a later change to the config reads properly.
# Deleted with the person and with the boss by the database (ON DELETE CASCADE).
class MerchClaim < ApplicationRecord
  STATUSES = %w[requested fulfilled cancelled].freeze

  belongs_to :user
  belongs_to :boss

  validates :item_key, presence: true, length: { maximum: 60 }
  validates :item_name, presence: true, length: { maximum: 100 }
  validates :status, inclusion: { in: STATUSES }
  validates :claimed_at, presence: true
  validates :boss_id, uniqueness: { scope: :user_id }

  scope :newest_first, -> { order(claimed_at: :desc, id: :desc) }
  # Requested first (the staff queue), then the rest, newest first inside each group.
  scope :queue_order, -> { order(Arel.sql("CASE status WHEN 'requested' THEN 0 ELSE 1 END"), claimed_at: :desc, id: :desc) }

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end
end
