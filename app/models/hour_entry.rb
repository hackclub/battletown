# One row of the hours ledger: coded time in integer seconds for one user on one local date. Append-only: a persisted
# row is read-only, and a mistake is corrected with a new `adjustment` row (negative or positive seconds and a note).
# Write through Hours::Credit (it enforces the daily cap, the backfill window and idempotency); read through
# Hours::Totals. Holds no personal data beyond the user reference: `hackatime_project` is only the project NAME and
# `created_by` is a short operator tag such as "rake:credit". Rows are deleted with the user by the database
# (ON DELETE CASCADE), not by the model, so there is no `dependent:` here and no delete trigger.
class HourEntry < ApplicationRecord
  SOURCES = %w[hackatime manual adjustment].freeze
  MAX_SECONDS = 86_400
  CREATED_BY_FORMAT = /\A[a-z0-9_:.-]{1,40}\z/

  belongs_to :user

  after_create_commit { Bosses::CheckDefeat.for_date(local_date) } # the weekly boss may have just fallen

  validates :source, inclusion: { in: SOURCES }
  validates :seconds, numericality: { only_integer: true, other_than: 0, in: -MAX_SECONDS..MAX_SECONDS }
  validates :seconds, numericality: { greater_than: 0, message: "must be positive unless the source is an adjustment" },
                      unless: -> { source == "adjustment" }
  validates :local_date, presence: true
  validates :idempotency_key, presence: true, length: { maximum: 120 }
  validates :hackatime_project, length: { in: 1..120 }, allow_nil: true
  validates :note, presence: true, unless: -> { source == "hackatime" }
  validates :note, length: { maximum: 200 }
  validates :created_by, format: { with: CREATED_BY_FORMAT }, allow_nil: true

  # Immutable once persisted (see above).
  def readonly? = persisted? || super
end
