# One line of an order's history: a status change, a tracking edit or a staff note. Written by the Orders services in the same
# transaction as the change, never edited or deleted by the app (rows go with the order, by the database, when a person is
# deleted). It holds ids and codes only: who (buyer, staff or system, plus the staff member's user id, nulled if they are deleted), what,
# from and to which status, the reason code, and a short note a staff member typed. The note is staff-only and never shown to
# the buyer, copied to the audit trail, or put in a message; the form tells staff to leave out personal details.
class OrderEvent < ApplicationRecord
  ACTIONS = %w[held released shipped fulfilled cancelled refunded tracking_updated note_added address_changed address_revealed address_purged].freeze
  ACTOR_KINDS = %w[buyer staff system].freeze
  # The events a buyer sees on their own order page: plain status changes, nothing staff-only.
  BUYER_ACTIONS = %w[shipped fulfilled cancelled refunded].freeze
  NOTE_MAX = 300

  belongs_to :order
  belongs_to :actor, class_name: "User", optional: true

  before_validation { self.note = note.to_s.squish.presence }

  validates :action, inclusion: { in: ACTIONS }
  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :from_status, :to_status, inclusion: { in: Order::STATUSES }, allow_nil: true
  validates :reason_code, format: { with: /\A[a-z_]{2,30}\z/ }, allow_nil: true
  validates :note, length: { maximum: NOTE_MAX }, presence: { if: -> { action == "note_added" } }
  validate :only_staff_have_an_actor

  scope :oldest_first, -> { order(:created_at, :id) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :for_buyer, -> { where(action: BUYER_ACTIONS) }

  before_create { self.created_at ||= Time.current }

  # Append-only: a saved row is read-only. (`delete` skips callbacks and the read-only check, so refuse it too; rows only
  # disappear with their order.)
  def readonly? = !new_record? || super

  def delete = raise(ActiveRecord::ReadOnlyRecord, "order events are append-only")

  before_destroy { raise ActiveRecord::ReadOnlyRecord, "order events are append-only" }

  def status_change? = from_status != to_status

  private

  # The buyer is the order's owner and the system is nobody: only a staff member is recorded by id.
  def only_staff_have_an_actor
    errors.add(:actor, "is only recorded for staff") if actor_kind != "staff" && actor_id
  end
end
