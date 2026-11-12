# A teen's request to turn the time coded on one project (since their last ship) into approved hours and coins.
#
# The window is snapshotted when the ship is saved: `coded_seconds`, the local dates it covers and the seconds per
# date (`daily_seconds`, { "2026-11-09" => 3600 }) and the Hackatime project names it covers (`hackatime_projects`),
# so hours coded afterwards belong to the next ship, approval never depends on the live ledger, and moving a link to
# another project cannot ship the same hours again (Ships::Window). Status: draft (editable), submitted (waiting for staff), approved (with
# `approved_seconds` <= coded), rejected (with a reason; the window is free again, so it can be fixed and shipped as
# a new ship) or withdrawn. Coins are never stored here: approval writes Coins::Ledger rows that reference the ship.
#
# Deleted with the user and with the project by the database (ON DELETE CASCADE). `reviewer_id` is a staff user and
# is nulled when that user is deleted. Transitions live in Ships::Submit, Ships::Approve, Ships::Reject and
# Ships::Withdraw (each locks the ship or the project row); the unique index allows one open ship per project.
class Ship < ApplicationRecord
  STATUSES = %w[draft submitted approved rejected withdrawn].freeze
  OPEN_STATUSES = %w[draft submitted].freeze
  # The statuses whose window is spoken for (a rejected or withdrawn ship gives its window back).
  WINDOW_STATUSES = %w[submitted approved].freeze
  DESCRIPTION_MAX = 1000
  URL_MAX = 300
  REASON_MAX = 300
  NOTE_MAX = 300

  belongs_to :user
  belongs_to :project
  belongs_to :reviewer, class_name: "User", optional: true
  # The ledger rows that reference this ship (approval and streak bonus). Read-only here: only for preloading
  # `coin_breakdown` on lists (`includes(:coin_transactions)`); the ledger itself is written by Coins::Ledger.
  has_many :coin_transactions, as: :reference, inverse_of: false
  # Screenshots (flag `ship_screenshots`; none while it is off). The bytes are not loaded here (ShipImage.without_content);
  # the database deletes them with the ship.
  has_many :images, -> { without_content.in_order }, class_name: "ShipImage", inverse_of: :ship

  before_validation :normalize_fields

  validates :status, inclusion: { in: STATUSES }
  validates :description, length: { maximum: DESCRIPTION_MAX }
  validates :description, presence: { message: "needs a few words about what you built" }, unless: :status_draft?
  validates :repo_url, presence: { message: "is needed so a reviewer can look at your code" }, unless: :status_draft?
  validates :coded_seconds, numericality: { only_integer: true, greater_than: 0 }
  validates :window_start_date, :window_end_date, presence: true
  validates :rejection_reason, length: { maximum: REASON_MAX }
  validates :rejection_reason, presence: true, if: :status_rejected?
  validates :rejection_reason, absence: true, unless: :status_rejected?
  validates :payout_note, length: { maximum: NOTE_MAX }
  validates :submitted_at, presence: true, unless: :status_draft?
  validates :reviewed_at, presence: true, if: -> { status_approved? || status_rejected? }
  validate :project_belongs_to_user
  validate :repo_url_is_a_github_repo
  validate :demo_url_is_https
  validate :window_is_consistent
  validate :approved_seconds_in_range
  validate :window_is_frozen_after_submission, on: :update
  validate :one_open_ship_per_project, if: :open?

  scope :open_now, -> { where(status: OPEN_STATUSES) }
  scope :waiting, -> { where(status: "submitted") }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  # Staff queue order: waiting ships first, oldest first; everything else after, newest first.
  scope :review_order, lambda {
    order(Arel.sql("(ships.status = 'submitted') DESC, CASE WHEN ships.status = 'submitted' THEN ships.submitted_at END ASC, ships.submitted_at DESC NULLS LAST, ships.id DESC"))
  }

  STATUSES.each do |name|
    define_method(:"status_#{name}?") { status == name }
  end

  def open? = OPEN_STATUSES.include?(status)

  # { Date => seconds } from the snapshot, oldest first.
  def daily_seconds_by_date
    daily_seconds.to_h { |date, seconds| [ Date.iso8601(date), Integer(seconds) ] }.sort.to_h
  end

  # The local dates that carried coded time (what the payout is spread over).
  def window_dates = daily_seconds_by_date.keys

  # What approval credited, read from the ledger: { base:, bonus:, total: } in coins (zeros before approval).
  # Uses the preloaded `coin_transactions` when the list loaded them, so a page of ships is one query, not one each.
  def coin_breakdown
    rows = if coin_transactions.loaded?
      coin_transactions.select { |row| row.user_id == user_id }.map { |row| [ row.kind, row.amount ] }
    else
      CoinTransaction.where(user_id: user_id, reference_type: self.class.name, reference_id: id).pluck(:kind, :amount)
    end
    base = rows.sum { |kind, amount| kind == "ship_approval" ? amount : 0 }
    bonus = rows.sum { |kind, amount| kind == "streak_bonus" ? amount : 0 }
    { base: base, bonus: bonus, total: base + bonus }
  end

  private

  def normalize_fields
    self.description = description.to_s.strip.presence
    self.repo_url = repo_url.to_s.strip.presence
    self.demo_url = demo_url.to_s.strip.presence
    self.rejection_reason = rejection_reason.to_s.squish.presence
  end

  def project_belongs_to_user
    errors.add(:project, "must be one of your projects") if project && user_id != project.user_id
  end

  # Same rule and tidying as Project (lowercase, no "www.", ".git" or trailing slash), through the same normaliser.
  def repo_url_is_a_github_repo
    return if repo_url.blank?

    normalized = repo_url.start_with?("https://", "HTTPS://") && repo_url.length <= URL_MAX ? Projects::RepoUrl.normalize(repo_url) : nil
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

  def window_is_consistent
    errors.add(:window_end_date, "cannot be before the start") if window_start_date && window_end_date && window_end_date < window_start_date
    return unless daily_seconds.is_a?(Hash)

    positive = daily_seconds.values.all? { |seconds| seconds.is_a?(Integer) && seconds.positive? }
    errors.add(:daily_seconds, "must add up to the coded time") unless positive && daily_seconds.values.sum == coded_seconds
  end

  def approved_seconds_in_range
    if status_approved?
      errors.add(:approved_seconds, "is needed to approve a ship") if approved_seconds.nil?
    elsif approved_seconds
      errors.add(:approved_seconds, "can only be set on an approved ship")
    end
    return unless approved_seconds

    errors.add(:approved_seconds, "must be more than zero") unless approved_seconds.positive?
    errors.add(:approved_seconds, "cannot be more than the hours coded") if coded_seconds && approved_seconds > coded_seconds
  end

  # Once submitted, the snapshot of what was coded never changes.
  def window_is_frozen_after_submission
    return if status_was == "draft"

    frozen = %w[coded_seconds window_start_date window_end_date daily_seconds hackatime_projects project_id user_id]
    errors.add(:base, "A submitted ship's hours cannot change") if frozen.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end

  def one_open_ship_per_project
    return unless project_id

    others = self.class.open_now.where(project_id: project_id)
    others = others.where.not(id: id) if persisted?
    errors.add(:base, "This project already has a ship waiting") if others.exists?
  end
end
