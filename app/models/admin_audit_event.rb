# One row of the staff audit trail: who (a staff member, nulled when they are deleted), what (an action from the
# AdminAudit allowlist), to which row (type and id) and when, plus a small `metadata` object of ids, amounts, reason codes
# and short staff-written reasons. It never holds what staff saw, and no personal data: AdminAudit::Metadata enforces the
# shape, and the subject row reaches the person through its own cascading key. Append-only: a persisted row is read-only.
# Write through AdminAudit.record!; read on /admin/audit.
class AdminAuditEvent < ApplicationRecord
  belongs_to :actor, class_name: "User", optional: true

  validates :action, inclusion: { in: ->(_) { AdminAudit::ACTIONS } }
  validates :subject_type, presence: true, length: { maximum: 60 }
  validates :subject_id, presence: true
  validate :metadata_is_clean

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :about, ->(type, id) { where(subject_type: type.to_s, subject_id: id) }

  def readonly? = !new_record? || super

  # `delete` skips callbacks and the read-only check, so refuse it too (rows only disappear with the database).
  def delete = raise(ActiveRecord::ReadOnlyRecord, "audit events are append-only")

  before_destroy { raise ActiveRecord::ReadOnlyRecord, "audit events are append-only" }

  private

  def metadata_is_clean
    AdminAudit::Metadata.problems(metadata).each { |problem| errors.add(:metadata, problem) }
  end
end
