# A minimal, append-only record that a staff member looked at something sensitive (see the migration). It never holds
# what they saw nor who the row was about: only the actor, an action name, the subject row (type and id) and the time.
class StaffAccessLog < ApplicationRecord
  ACTIONS = %w[nps_comment_author_viewed].freeze

  belongs_to :actor, class_name: "User", optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :subject_type, presence: true, length: { maximum: 60 }
  validates :subject_id, presence: true

  # Records one access. `subject` is any record; only its class name and id are stored.
  def self.record!(actor:, action:, subject:)
    create!(actor: actor, action: action, subject_type: subject.class.name, subject_id: subject.id, created_at: Time.current)
  end

  def readonly? = persisted?
end
