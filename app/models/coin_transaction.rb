# One row of the coin ledger. Append-only: persisted rows are read-only, never updated or destroyed by the app (rows
# only disappear when the database cascades a user deletion). Write through Coins::Ledger, which serialises per user
# and refuses a negative balance; read the balance with Coins::Balance.
class CoinTransaction < ApplicationRecord
  CREDIT_KINDS = %w[ship_approval streak_bonus refund].freeze
  DEBIT_KINDS = %w[purchase].freeze
  KINDS = (CREDIT_KINDS + DEBIT_KINDS + %w[adjustment]).freeze
  KEY_MAX = 120
  NOTE_MAX = 200
  CREATED_BY_FORMAT = /\A[a-z0-9_:.-]{1,40}\z/

  belongs_to :user

  validates :amount, numericality: { only_integer: true, other_than: 0 }
  validates :kind, inclusion: { in: KINDS }
  validates :idempotency_key, presence: true, length: { maximum: KEY_MAX }
  validates :note, length: { maximum: NOTE_MAX }
  validates :created_by, format: { with: CREATED_BY_FORMAT }, allow_nil: true
  validates :reference_type, length: { maximum: 60 }, allow_nil: true
  validate :sign_matches_kind
  validate :reference_is_complete

  def readonly? = !new_record? || super

  # `delete` skips callbacks and the read-only check, so refuse it too.
  def delete = raise(ActiveRecord::ReadOnlyRecord, "coin transactions are append-only")

  before_destroy { raise ActiveRecord::ReadOnlyRecord, "coin transactions are append-only" }

  private

  def sign_matches_kind
    return if amount.nil?

    errors.add(:amount, "must be positive for #{kind}") if CREDIT_KINDS.include?(kind) && amount.negative?
    errors.add(:amount, "must be negative for #{kind}") if DEBIT_KINDS.include?(kind) && amount.positive?
  end

  def reference_is_complete
    errors.add(:reference_id, "is required with a reference type") if reference_type.present? && reference_id.nil?
    errors.add(:reference_type, "is required with a reference id") if reference_id.present? && reference_type.blank?
  end
end
