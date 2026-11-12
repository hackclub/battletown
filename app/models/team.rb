# A crew of friends who code on the same days (the "team bonus", flag `team`). Created and changed only through Teams::Crew.
# The invite token is the only way in: random, unique, short-lived, replaced to revoke. Members can see each other's display
# names and nothing else. A crew with no members is deleted (Team.sweep_empty!).
class Team < ApplicationRecord
  NAME_MAX = 40
  TOKEN_FORMAT = /\A[A-Za-z0-9_-]{16,32}\z/
  # The same shape for the router (no anchors there).
  TOKEN_FORMAT_PATH = /[A-Za-z0-9_-]{16,32}/
  # 12 random bytes = 96 bits, 16 URL-safe characters.
  TOKEN_BYTES = 12

  has_many :memberships, class_name: "TeamMembership", dependent: nil
  has_many :users, through: :memberships
  has_many :payouts, class_name: "TeamPayout", dependent: nil

  normalizes :name, with: ->(name) { name.to_s.squish.presence }

  validates :name, length: { maximum: NAME_MAX }, allow_nil: true
  validates :invite_token, format: { with: TOKEN_FORMAT }, uniqueness: true
  validates :invite_expires_at, presence: true
  validate :name_has_no_control_characters

  def self.new_token = SecureRandom.urlsafe_base64(TOKEN_BYTES)

  # Crews with nobody in them (the last member left or their account was deleted). Returns how many were removed.
  def self.sweep_empty!
    where.not(id: TeamMembership.select(:team_id)).delete_all
  end

  def invite_active?(now = Time.current) = invite_expires_at > now

  # The member who has been in the longest (ties: the lower membership id). Called "the inviter" on the join page.
  def founder
    memberships.includes(:user).order(:joined_at, :id).first&.user
  end

  private

  def name_has_no_control_characters
    errors.add(:name, "can only use letters, numbers and punctuation") if name&.match?(/[[:cntrl:]]/)
  end
end
