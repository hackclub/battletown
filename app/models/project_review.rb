# One staff decision about a project: it looks fine (`ok`) or it needs a closer look (`flagged`, with a reason). Append-only
# history: the newest row is the current state and projects.review_status copies it (written together, Projects::Review).
# Staff only. A review never changes coding, hours, coins or whether the teen can ship, and the teen never sees it.
# Rows are deleted with the project by the database (ON DELETE CASCADE); `reviewer_id` is nulled when that staff member is deleted.
class ProjectReview < ApplicationRecord
  STATUSES = %w[ok flagged].freeze
  NOTE_MAX = 500

  belongs_to :project
  belongs_to :reviewer, class_name: "User", optional: true

  before_validation { self.note = note.to_s.strip.presence }

  validates :status, inclusion: { in: STATUSES }
  validates :note, length: { maximum: NOTE_MAX }
  validates :note, presence: { message: "is needed to flag a project: say why" }, if: :flagged?
  validate :reviewer_is_not_the_owner

  scope :latest_first, -> { order(created_at: :desc, id: :desc) }

  STATUSES.each { |name| define_method(:"#{name}?") { status == name } }

  # Append-only: a saved review is never edited.
  def readonly? = persisted? || super

  private

  def reviewer_is_not_the_owner
    errors.add(:base, Projects::Review::OWN_PROJECT_MESSAGE) if project && reviewer_id && reviewer_id == project.user_id
  end
end
