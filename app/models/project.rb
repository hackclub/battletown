# Something a teen is building. A user has many (MAX_PER_USER) but exactly one is the active one at a time
# (`active`, backed by a partial unique index); `status` is separate: archived projects are tucked away and can
# never be the active one. Hackatime projects attach through HackatimeLink; `User#active_project` is the
# one other features should read.
class Project < ApplicationRecord
  KINDS = User::PROJECT_KINDS
  STATUSES = %w[active archived].freeze
  GUIDE_KEYS = %w[sd playground].freeze # nil for none; guides themselves are not built yet
  MAX_PER_USER = 10
  NAME_RANGE = 1..60
  IDEA_MAX = 500
  URL_MAX = 300
  KIND_NAMES = { "game" => "My game", "website" => "My website", "app" => "My app", "tool" => "My tool",
                 "hardware" => "My hardware project" }.freeze

  belongs_to :user
  has_many :hackatime_links, dependent: :destroy
  has_many :link_suggestions, dependent: :destroy

  before_validation :normalize_fields
  before_validation :claim_active_slot, on: :create

  validates :name, length: { in: NAME_RANGE }
  validates :kind, inclusion: { in: KINDS }
  validates :idea, length: { maximum: IDEA_MAX }
  validates :status, inclusion: { in: STATUSES }
  validates :guide_key, inclusion: { in: GUIDE_KEYS }, allow_nil: true
  validate :repo_url_is_a_github_repo
  validate :demo_url_is_https
  validate :within_project_limit, on: :create
  validate :archived_cannot_be_active

  scope :live, -> { where(status: "active") }
  scope :archived, -> { where(status: "archived") }
  scope :oldest_first, -> { order(:created_at, :id) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  STATUSES.each do |name|
    define_method(:"status_#{name}?") { status == name }
  end

  # A short title for a project the user has not named: the first sentence of the idea (shortened), else "My <kind>".
  def self.default_name(kind:, idea:)
    title = idea.to_s.split(/[.!?\n]/).first.to_s.squish
    title = title.truncate(40, separator: " ", omission: "").sub(/[\s,;:\-]+\z/, "")
    title = title[0].upcase + title[1..] if title.present?
    title.presence || KIND_NAMES.fetch(kind.to_s, "My project")
  end

  # The onboarding project step: creates the user's first project from users.project_kind / project_idea, or
  # updates it when they come back to the step. A name the user never changed (still the derived one) follows
  # the new answers; a name they chose is kept. Returns true when saved.
  def self.sync_first_from_onboarding(user)
    project = user.projects.oldest_first.first
    if project
      derived = project.name == default_name(kind: project.kind, idea: project.idea)
      project.assign_attributes(kind: user.project_kind, idea: user.project_idea)
      project.name = default_name(kind: project.kind, idea: project.idea) if derived
    else
      project = user.projects.build(kind: user.project_kind, idea: user.project_idea,
                                    name: default_name(kind: user.project_kind, idea: user.project_idea))
    end
    project.save
  end

  # Names of the Hackatime projects linked to this project, in link order.
  def hackatime_project_names = hackatime_links.order(:id).pluck(:hackatime_project)

  # Makes this the user's single active project. Locking the user serialises concurrent switches; the partial
  # unique index is the backstop. Archived projects cannot be activated (returns false).
  def make_active!
    return false unless status_active?

    user.with_lock do
      user.projects.where(active: true).where.not(id: id).update_all(active: false, updated_at: Time.current)
      update!(active: true) unless active?
    end
    true
  end

  # Tucks the project away. If it was the active one, the user's newest remaining live project takes over so
  # there is still something to log time against; returns that project (or nil).
  def archive!
    user.with_lock do
      was_active = active?
      update!(status: "archived", active: false)
      promote_replacement if was_active
    end
  end

  def unarchive!
    update!(status: "active")
    # Nothing active yet (their only live project was archived)? This one becomes it.
    user.with_lock { make_active! if user.projects.where(active: true).none? }
    true
  end

  # Deletes the project (its links and suggestions go with it) and hands the active flag on like archive! does.
  def discard!
    user.with_lock do
      was_active = active?
      destroy!
      self.class.promote_for(user) if was_active
    end
  end

  def self.promote_for(user)
    replacement = user.projects.live.newest_first.first
    replacement&.update!(active: true)
    replacement
  end

  private

  def promote_replacement = self.class.promote_for(user)

  # A new project is the active one only when the user has none yet; callers never choose (see make_active!).
  def claim_active_slot
    self.active = status_active? && user.present? && user.projects.where(active: true).none?
  end

  def normalize_fields
    self.name = name.to_s.squish
    self.idea = idea.to_s.strip.presence
    self.repo_url = repo_url.to_s.strip.presence
    self.demo_url = demo_url.to_s.strip.presence
    self.guide_key = guide_key.presence
  end

  # Input must be https; "www.", ".git", a trailing slash and capitals are tidied (RepoUrl), anything else is refused.
  def repo_url_is_a_github_repo
    return if repo_url.blank?

    normalized = repo_url.start_with?("https://", "HTTPS://") ? Projects::RepoUrl.normalize(repo_url) : nil
    if normalized
      self.repo_url = normalized
    else
      errors.add(:repo_url, "should look like https://github.com/your-name/your-repo")
    end
  end

  def demo_url_is_https
    return if demo_url.blank?

    if demo_url.length > URL_MAX
      errors.add(:demo_url, "is too long (the limit is #{URL_MAX} characters)")
    elsif (uri = parse_https(demo_url))
      self.demo_url = uri.to_s
    else
      errors.add(:demo_url, "should be a full link starting with https://")
    end
  end

  def parse_https(text)
    return if text.match?(/[[:space:][:cntrl:]]/)

    uri = URI.parse(text)
    return unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.host.include?(".") && uri.userinfo.nil?

    uri.host = uri.host.downcase
    uri
  rescue URI::InvalidURIError
    nil
  end

  def within_project_limit
    return unless user && user.projects.where.not(id: id).count >= MAX_PER_USER

    errors.add(:base, "You can have up to #{MAX_PER_USER} projects. Delete one you no longer need to add another")
  end

  def archived_cannot_be_active
    errors.add(:active, "project cannot be archived") if active? && status_archived?
  end
end
