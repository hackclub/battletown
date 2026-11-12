# A short private note staff leave about a person. Staff-written, shown to staff only (the admin user page), never to the
# person. Append-only: a saved note is read-only and the app never deletes one; the database removes them with the person
# (ON DELETE CASCADE) and forgets the author if that staff member is deleted (ON DELETE SET NULL). Write through
# AdminUsers::AddNote, which also records the audit event.
class UserNote < ApplicationRecord
  BODY_MAX = 500

  belongs_to :user
  belongs_to :author, class_name: "User", optional: true

  normalizes :body, with: ->(text) { text.to_s.gsub(/[[:cntrl:]&&[^\n]]/, " ").gsub(/[ \t]+/, " ").strip }
  validates :body, presence: true, length: { maximum: BODY_MAX }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def readonly? = !new_record? || super

  def delete = raise(ActiveRecord::ReadOnlyRecord, "staff notes are append-only")

  before_destroy { raise ActiveRecord::ReadOnlyRecord, "staff notes are append-only" }
end
