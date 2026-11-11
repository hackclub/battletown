# Outbox row for an outbound notification. Holds no message text and no recipient address (see the migration):
# the text is built from `kind` at send time and the recipient is the user's Slack id at send time.
class Notification < ApplicationRecord
  KINDS = %w[daily_reminder].freeze
  CHANNELS = %w[slack_dm].freeze
  STATUSES = %w[pending sent failed cancelled].freeze
  MAX_ATTEMPTS = 10 # mirrors the notifications_attempts_check constraint
  ERROR_CODE_FORMAT = /\A[a-z0-9_]{1,40}\z/

  belongs_to :user

  validates :kind, inclusion: { in: KINDS }
  validates :channel, inclusion: { in: CHANNELS }
  validates :status, inclusion: { in: STATUSES }
  validates :scheduled_for, :due_at, presence: true
  validates :attempts, numericality: { only_integer: true, in: 0..MAX_ATTEMPTS }
  validates :last_error_code, format: { with: ERROR_CODE_FORMAT }, allow_nil: true
  validates :idempotency_key, presence: true, uniqueness: true, length: { maximum: 100 }

  scope :pending, -> { where(status: "pending") }
  scope :due, ->(now) { pending.where(due_at: ..now) }

  def self.idempotency_key_for(kind:, user_id:, scheduled_for:)
    "#{kind}:#{user_id}:#{scheduled_for.utc.iso8601}"
  end

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end
end
