# The link between a Battletown user and their Hackatime account (docs/HACKATIME.md). Identity is the Hackatime
# user id, never a Slack id match. Tokens are encrypted at rest (Active Record encryption) and are never logged:
# encrypted attributes are filtered from #inspect automatically.
class HackatimeConnection < ApplicationRecord
  # Refresh a little before the token really expires so a request never races the clock.
  EXPIRY_SKEW = 60.seconds
  REQUIRED_SCOPES = %w[profile read].freeze
  UID_FORMAT = /\A[0-9]{1,20}\z/

  belongs_to :user

  encrypts :access_token, :refresh_token

  validates :user_id, uniqueness: true
  validates :hackatime_uid, presence: true, format: { with: UID_FORMAT }, uniqueness: true
  validates :access_token, presence: true
  validates :connected_at, presence: true
  validates :scopes, length: { maximum: 100 }
  validates :last_error_code, format: { with: /\A[a-z0-9_]{1,40}\z/ }, allow_nil: true

  def scope_list = scopes.to_s.split

  def scope_satisfied? = (REQUIRED_SCOPES - scope_list).empty?

  def expired?(now: Time.current) = expires_at.present? && expires_at <= now + EXPIRY_SKEW

  def mark_needs_reconnect!(code)
    update!(needs_reconnect: true, last_error_code: code.to_s)
  end

  def record_sync!(at: Time.current)
    update!(last_synced_at: at, last_error_code: nil)
  end
end
