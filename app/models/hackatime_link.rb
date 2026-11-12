# A Hackatime project (by its exact name) counted toward one of the user's projects. A Hackatime project links to
# at most one project per user (unique index on user_id + hackatime_project, also checked here for a friendly error).
class HackatimeLink < ApplicationRecord
  METHODS = %w[manual auto_repo confirmed].freeze
  NAME_MAX = 120
  # Letters, digits, spaces and the punctuation project folders usually contain. No control characters, no quotes
  # or angle brackets; must start with a letter or digit.
  NAME_FORMAT = %r{\A[\p{L}\p{N}][\p{L}\p{N} ._\-/:+#@()~\[\]]*\z}
  MAX_PER_PROJECT = 20

  belongs_to :user
  belongs_to :project

  before_validation { self.hackatime_project = hackatime_project.to_s.strip }

  validates :hackatime_project, length: { in: 1..NAME_MAX }, format: { with: NAME_FORMAT, message: "can only use letters, numbers, spaces and . _ - / : + # @ ( ) ~ [ ]" }
  validates :hackatime_project, uniqueness: { scope: :user_id, message: "is already linked to one of your projects" }
  validates :link_method, inclusion: { in: METHODS }
  validate :project_belongs_to_user
  validate :within_link_limit, on: :create

  # The user's project a Hackatime project name is linked to, or nil.
  def self.project_for(user, hackatime_project)
    find_by(user_id: user.id, hackatime_project: hackatime_project.to_s.strip)&.project
  end

  private

  def project_belongs_to_user
    errors.add(:project, "must be one of your projects") if project && user_id != project.user_id
  end

  def within_link_limit
    return unless project && project.hackatime_links.count >= MAX_PER_PROJECT

    errors.add(:base, "A project can link up to #{MAX_PER_PROJECT} Hackatime projects")
  end
end
