module Admin
  # Staff project review: a paginated queue of every project (filters, search, sort), one project with its context and review
  # history, and the review writes (OK, flag, clear, note; Projects::Review). Staff only; nothing here changes what a teen can do.
  # Viewing is not logged; every write is (inside Projects::Review). The queue shows the owner's display name only (never email,
  # Slack id or Hack Club Auth id). Search terms travel in the query string `q`, which is filtered from request logs.
  class ProjectsController < BaseController
    PER_PAGE = AdminPager::PER_PAGE
    SEARCH_MAX = 100
    REVIEW_FILTERS = %w[unreviewed flagged ok].freeze
    STATUS_FILTERS = %w[active archived].freeze
    YES_NO = %w[yes no].freeze
    SORTS = { "newest" => "projects.created_at DESC, projects.id DESC", "oldest" => "projects.created_at ASC, projects.id ASC",
              "hours" => "COALESCE(coded.coded_seconds, 0) DESC, projects.id DESC" }.freeze
    # Fixed SQL, picked by the whitelisted yes/no value (nothing from the request is ever put into a query string).
    SHIPPED_SQL = { "yes" => "EXISTS (SELECT 1 FROM ships WHERE ships.project_id = projects.id AND ships.status <> 'draft')",
                    "no" => "NOT EXISTS (SELECT 1 FROM ships WHERE ships.project_id = projects.id AND ships.status <> 'draft')" }.freeze
    LINKED_SQL = { "yes" => "EXISTS (SELECT 1 FROM hackatime_links WHERE hackatime_links.project_id = projects.id)",
                   "no" => "NOT EXISTS (SELECT 1 FROM hackatime_links WHERE hackatime_links.project_id = projects.id)" }.freeze
    HISTORY_LIMIT = 100
    SHIPS_LIMIT = 50
    NOTICES = { ok: "Marked OK.", flag: "Flagged. Nothing changes for the teen; staff see the flag.", clear: "Flag cleared.", note: "Note added." }.freeze

    before_action :set_project, only: %i[show ok flag clear note]

    def index
      @filters = filters
      scope = filtered(Project.all)
      @total = scope.count
      @pager = AdminPager.new(total: @total, page: params[:page])
      @projects = @pager.apply(scope.joins(Projects::CodedTime.join_sql)
                                    .select("projects.*, COALESCE(coded.coded_seconds, 0) AS coded_seconds")
                                    .includes(:user).reorder(Arel.sql(SORTS.fetch(@filters[:sort])))).to_a
      @ship_counts = ship_counts(@projects)
      @review_counts = Project.group(:review_status).count
    end

    def show
      load_context
    end

    def ok = review(:ok) { Projects::Review.ok(project: @project, reviewer: current_user, note: text(:note)) }

    def flag = review(:flag) { Projects::Review.flag(project: @project, reviewer: current_user, preset: text(:reason_preset), details: text(:details)) }

    def clear = review(:clear) { Projects::Review.clear(project: @project, reviewer: current_user, note: text(:note)) }

    def note = review(:note) { Projects::Review.add_note(project: @project, reviewer: current_user, note: text(:note)) }

    private

    def set_project = @project = Project.includes(:user).find(params[:id])

    def review(action)
      yield
      redirect_to admin_project_path(@project), notice: NOTICES.fetch(action), status: :see_other
    rescue Projects::Review::Invalid => error
      @project.reload
      @error = error.message
      @form = { action: action, note: text(:note), reason_preset: text(:reason_preset), details: text(:details) }
      load_context
      render :show, status: :unprocessable_content
    end

    def load_context
      @links = @project.hackatime_project_names
      @seconds_by_date = Projects::CodedTime.seconds_by_date(@project)
      @weeks = Projects::CodedTime.by_week(@seconds_by_date).first(26)
      @ships = @project.ships.where.not(status: "draft").order(submitted_at: :desc, id: :desc).limit(SHIPS_LIMIT).to_a
      @reviews = @project.project_reviews.includes(:reviewer).limit(HISTORY_LIMIT).to_a
    end

    # Only whitelisted values survive (anything else, arrays and hashes included, falls back to "no filter").
    def filters
      {
        review: text(:review).presence_in(REVIEW_FILTERS),
        status: text(:status).presence_in(STATUS_FILTERS),
        shipped: text(:shipped).presence_in(YES_NO),
        linked: text(:linked).presence_in(YES_NO),
        sort: text(:sort).presence_in(SORTS.keys) || "newest",
        q: search_text
      }.compact
    end

    def filtered(scope)
      scope = scope.where(review_status: @filters[:review]) if @filters[:review]
      scope = scope.where(status: @filters[:status]) if @filters[:status]
      scope = scope.where(SHIPPED_SQL.fetch(@filters[:shipped])) if @filters[:shipped]
      scope = scope.where(LINKED_SQL.fetch(@filters[:linked])) if @filters[:linked]
      return scope unless @filters[:q]

      pattern = "%#{Project.sanitize_sql_like(@filters[:q])}%"
      scope.where("projects.name ILIKE :pattern OR projects.repo_url ILIKE :pattern", pattern: pattern)
    end

    # { project_id => { "approved" => 1, "submitted" => 1 } } for the page, in one query. Drafts are the teen's own and never listed.
    def ship_counts(projects)
      Ship.where(project_id: projects.map(&:id)).where.not(status: "draft").group(:project_id, :status).count
          .each_with_object(Hash.new { |hash, key| hash[key] = {} }) { |((project_id, status), count), by_project| by_project[project_id][status] = count }
    end

    def text(key) = params[key].is_a?(String) ? params[key] : ""

    def search_text
      term = text(:q).scrub("").delete("\u0000").squish.first(SEARCH_MAX)
      term.presence
    end
  end
end
