# Outbox row for an outbound notification. Holds no message text and no recipient address (see the migration):
# the text is built from `kind` at send time and the recipient is the user's Slack id at send time.
class Notification < ApplicationRecord
  # daily_reminder is scheduled from the user's coding days (Notifications::Scheduler); the others are about one thing
  # (`subject_id`): link_question a LinkSuggestion, ship_reminder / ship_mvp a Project, ship_approved / ship_rejected a Ship,
  # returning_nudge the day count (since 1970-01-01) of the user's last active day (feature flag `returning`),
  # nps_prompt a survey window (the user's local date as a number, 20261113; feature flag `nps`).
  KINDS = %w[daily_reminder link_question ship_reminder ship_mvp ship_approved ship_rejected returning_nudge nps_prompt].freeze
  EVENT_KINDS = (KINDS - %w[daily_reminder]).freeze
  CHANNELS = %w[slack_dm email].freeze
  # skipped: handled by an adapter that does not really deliver (the log adapter in development, the null adapter in
  # tests), so nothing reached Slack; last_error_code says why. Never recorded as sent.
  STATUSES = %w[pending sent failed cancelled skipped].freeze
  MAX_ATTEMPTS = 10 # mirrors the notifications_attempts_check constraint
  ERROR_CODE_FORMAT = /\A[a-z0-9_]{1,40}\z/

  belongs_to :user

  validates :kind, inclusion: { in: KINDS }
  validates :channel, inclusion: { in: CHANNELS }
  validates :status, inclusion: { in: STATUSES }
  validates :scheduled_for, :due_at, presence: true
  validates :subject_id, presence: true, if: -> { EVENT_KINDS.include?(kind) }
  validates :attempts, numericality: { only_integer: true, in: 0..MAX_ATTEMPTS }
  validates :last_error_code, format: { with: ERROR_CODE_FORMAT }, allow_nil: true
  validates :idempotency_key, presence: true, uniqueness: true, length: { maximum: 100 }

  # A Slack nudge that also goes by email queues its email row (Notifications::Email::Triggers; a no-op while the `email`
  # flag is off). After commit, so a failure there can never touch the transaction that created the Slack row.
  after_create_commit -> { Notifications::Email::Triggers.slack_row_created(self) },
                      if: -> { channel == "slack_dm" && Notifications::Email::FOLLOWS_SLACK_ROW.include?(kind) }

  scope :pending, -> { where(status: "pending") }
  scope :due, ->(now) { pending.where(due_at: ..now) }

  def self.idempotency_key_for(kind:, user_id:, scheduled_for:)
    "#{kind}:#{user_id}:#{scheduled_for.utc.iso8601}"
  end

  STATUSES.each do |name|
    define_method(:"#{name}?") { status == name }
  end
end
