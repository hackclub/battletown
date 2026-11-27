# Something a teen is building. A user has many (MAX_PER_USER) but exactly one is the active one at a time
# (`active`, backed by a partial unique index); `status` is separate: archived projects are tucked away and can
# never be the active one. Hackatime projects attach through HackatimeLink; `User#active_project` is the
# one other features should read.
class Project < ApplicationRecord
  KINDS = User::PROJECT_KINDS
  STATUSES = %w[active archived].freeze
  REVIEW_STATUSES = %w[unreviewed ok flagged].freeze # staff only; see ProjectReview and projects/battletown/specs/contract.md "Project review"
  GUIDE_KEYS = %w[sd playground].freeze # nil for none; guides themselves are not built yet
  MAX_PER_USER = 10
  NAME_RANGE = 1..60
  TODOS_MAX = 10 # things to work on this commit; the page offers one empty line at a time
  TODO_MAX = 120
  IDEA_MAX = 500
  URL_MAX = 300
  DANGLING_TAIL = /(?:[\s,;:\-]+(?:a|an|the|in|of|on|to|and|or|for|with|where|that|is|are))*[\s,;:\-]*\z/i # a cut-off title should not end on "in"
  DEFAULT_NAME_MAX = 50 # a derived name, well inside NAME_RANGE so it still fits a card
  ELLIPSIS = "…".freeze
  LEADING_PUNCTUATION = /\A[\s.,;:!?\-–…]+/
  TRAILING_PUNCTUATION = /[\s.,;:!?\-–]+\z/
  KIND_NAMES = { "game" => "My game", "website" => "My website", "app" => "My app", "tool" => "My tool",
                 "hardware" => "My hardware project" }.freeze

  belongs_to :user
  has_many :hackatime_links, dependent: :destroy
  has_many :link_suggestions, dependent: :destroy
  has_many :ships, dependent: :destroy
  # Staff review history (deleted with the project by the database). The teen never sees it; the denormalised
  # `review_status` / `reviewed_at` are written only by Projects::Review, never through the project form.
  has_many :project_reviews, -> { latest_first }, inverse_of: :project

  before_validation :normalize_fields
  before_validation :claim_active_slot, on: :create

  validates :name, length: { in: NAME_RANGE }
  validates :kind, inclusion: { in: KINDS }
  validates :idea, length: { maximum: IDEA_MAX }
  validates :status, inclusion: { in: STATUSES }
  validates :review_status, inclusion: { in: REVIEW_STATUSES }
  validates :guide_key, inclusion: { in: GUIDE_KEYS }, allow_nil: true
  validate :repo_url_is_a_github_repo
  validate :demo_url_is_https
  validate :within_project_limit, on: :create
  validate :archived_cannot_be_active
  validate :todos_are_short

  scope :live, -> { where(status: "active") }
  scope :archived, -> { where(status: "archived") }
  scope :oldest_first, -> { order(:created_at, :id) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  STATUSES.each do |name|
    define_method(:"status_#{name}?") { status == name }
  end

  REVIEW_STATUSES.each do |name|
    define_method(:"review_#{name}?") { review_status == name }
  end

  # Replaces the to-do list from form entries (`{ "1" => { "body" => "...", "done" => "1" }, "2" => ... }` or an array of those hashes):
  # taken in the order of the numbers (the page numbers its lines as it adds them, so they may have gaps), blanks dropped, each cut
  # at TODO_MAX characters, `done` a real boolean, at most TODOS_MAX kept. Only the first MAX_ENTRIES lines are looked at.
  MAX_ENTRIES = 50

  def self.clean_todos(entries)
    list = if entries.respond_to?(:key?)
      entries.keys.select { |key| key.to_s.match?(/\A\d{1,6}\z/) }.sort_by(&:to_i).first(MAX_ENTRIES).map { |key| entries[key] }
    else
      Array(entries).first(MAX_ENTRIES)
    end
    list.filter_map do |entry|
      entry = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry
      next unless entry.respond_to?(:[])

      body = entry["body"].to_s.squish.first(TODO_MAX)
      next if body.empty?

      { "body" => body, "done" => ActiveModel::Type::Boolean.new.cast(entry["done"]) == true }
    end.first(TODOS_MAX)
  end

  # A title for a project the user has not named: the first sentence of the idea, whole when it is short, else cut
  # at a word and ended with an ellipsis so it never reads as a finished sentence; "My <kind>" when there is no idea.
  def self.default_name(kind:, idea:)
    sentence = idea.to_s.split(/(?<=[.!?])\s+|\n/).first.to_s.squish.sub(LEADING_PUNCTUATION, "")
    title = shorten(sentence.sub(TRAILING_PUNCTUATION, ""))
    title = title[0].upcase + title[1..] if title.present?
    title.presence || KIND_NAMES.fetch(kind.to_s, "My project")
  end

  def self.shorten(title)
    return title if title.length <= DEFAULT_NAME_MAX

    room = DEFAULT_NAME_MAX - ELLIPSIS.length
    head = +""
    title.each_grapheme_cluster do |cluster| # never split an emoji
      break if head.length + cluster.length > room

      head << cluster
    end
    head = head.sub(/\s+\S*\z/, "") if head.include?(" ") && !title[head.length].to_s.match?(/\s/) # drop a half-cut word
    head = head.sub(TRAILING_PUNCTUATION, "").sub(DANGLING_TAIL, "").sub(TRAILING_PUNCTUATION, "")
    head.empty? ? "" : head + ELLIPSIS
  end
  private_class_method :shorten

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

  # A project with a ship waiting for review or already approved is kept (its history backs the coins); archive it instead.
  def deletable? = ships.where(status: Ship::WINDOW_STATUSES).none?

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

  def todos_are_short
    list = todos
    return if list.is_a?(Array) && list.size <= TODOS_MAX && list.all? { |item| item.is_a?(Hash) && item["body"].is_a?(String) && item["body"].length.between?(1, TODO_MAX) }

    errors.add(:todos, "are not valid")
  end
end
