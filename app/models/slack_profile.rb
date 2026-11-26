# What Battletown keeps from one player's Slack profile (see the migration for the why): a sanitised display name and a
# small re-encoded WebP picture (never the Slack real name), plus the state of the daily refresh (SlackProfiles::Refresh). Reading the list of profiles or a
# status never loads the picture bytes: `without_picture` is the default way to read a row, and only the avatar route loads them.
class SlackProfile < ApplicationRecord
  # What the last attempt came to (the admin page and `rake slack:profile_status` print it). `ok` means a name and picture were read;
  # `no_picture` that Slack has only its default picture for the person (nothing is stored, the generated avatar stays).
  STATUSES = %w[pending ok no_picture missing_scope invalid_auth not_found no_token ratelimited error].freeze
  # The most a stored picture may weigh (the database check is the same number). A 128 px WebP is about 5 KB.
  MAX_PICTURE_BYTES = 100_000
  NAME_MAX = 30
  CONTENT_TYPE = "image/webp".freeze

  belongs_to :user

  validates :status, inclusion: { in: STATUSES }
  validates :display_name, length: { maximum: NAME_MAX }
  validates :picture_bytes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_PICTURE_BYTES }, allow_nil: true
  validates :picture_sha256, format: { with: /\A\h{64}\z/ }, allow_nil: true

  scope :without_picture, -> { select(column_names - [ "picture" ]) }
  scope :with_picture, -> { where.not(picture_sha256: nil) }

  class << self
    # The row for `user` without its picture bytes, or nil.
    def for(user) = without_picture.find_by(user_id: user.id)

    # The short version tag of the picture to show for this person (the avatar address carries it, so a changed picture is a new
    # address), or nil: no row, the picture switched off, or no picture stored. One small query, never the bytes.
    def picture_version(user_id)
      where(user_id: user_id, use_picture: true).where.not(picture_sha256: nil).pick(:picture_sha256)&.first(10)
    end
  end

  def picture? = picture_sha256.present?

  # Whether the next refresh may run now (the daily gate and the back-off after a failure; SlackProfiles::Refresh).
  def due?(now = Time.current)
    return false if next_attempt_at && next_attempt_at > now

    fetched_at.nil? || fetched_at <= now - SlackProfiles::REFRESH_EVERY
  end
end
