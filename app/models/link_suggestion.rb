# "Is this Hackatime project yours?" for one of the user's projects. Nothing is linked until it is accepted
# (Projects::LinkSuggestions.accept!). A declined suggestion stays in the table so it is never asked again.
class LinkSuggestion < ApplicationRecord
  STATES = %w[pending accepted declined].freeze

  belongs_to :project

  before_validation { self.hackatime_project = hackatime_project.to_s.strip }

  validates :hackatime_project, length: { in: 1..HackatimeLink::NAME_MAX }, format: { with: HackatimeLink::NAME_FORMAT }
  validates :hackatime_project, uniqueness: { scope: :project_id }
  validates :state, inclusion: { in: STATES }

  scope :pending, -> { where(state: "pending") }

  STATES.each do |name|
    define_method(:"#{name}?") { state == name }
  end
end
