class ProjectsController < ApplicationController
  before_action :require_login, :require_onboarded
  # Every project lookup goes through current_user.projects: someone else's id is a plain 404.
  before_action :set_project, only: %i[edit update destroy activate archive unarchive link save_link]

  def index
    @live = current_user.projects.live.oldest_first.includes(:hackatime_links)
    @archived = current_user.projects.archived.oldest_first.includes(:hackatime_links)
    @suggestions = current_user.link_suggestions.pending.includes(:project).order(:id)
  end

  def new
    @project = current_user.projects.build(kind: "undecided")
  end

  def create
    @project = current_user.projects.build(project_params)
    # The lock keeps two quick submits from slipping past the project limit.
    saved = current_user.with_lock { @project.save }
    if saved
      redirect_to projects_path, notice: "#{@project.name} added.#{' It is your active project.' if @project.active?}"
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
    @suggestions = @project.link_suggestions.pending.order(:id)
    @links = @project.hackatime_links.order(:id)
  end

  def update
    if @project.update(project_params)
      redirect_to projects_path, notice: "Saved."
    else
      @suggestions = @project.link_suggestions.pending.order(:id)
      @links = @project.hackatime_links.order(:id)
      render :edit, status: :unprocessable_content
    end
  end

  # The short way to link Hackatime, from the dashboard: only the name and the Hackatime projects, chosen from a searchable
  # list of the ones they have coded on. The long edit page keeps every other field.
  def link
    load_hackatime_options
  end

  def save_link
    chosen = params.dig(:hackatime_link, :hackatime_projects)
    names = chosen.is_a?(Array) ? chosen : Array(params.dig(:hackatime_link, :hackatime_project)) # the typed field, when the list was not available
    result = Projects::LinkHackatime.call(project: @project, user: current_user, project_name: params.dig(:project, :name), hackatime_names: names)
    if result.ok?
      redirect_to dashboard_path, notice: "Linked #{result.links.map(&:hackatime_project).to_sentence}.", status: :see_other
    else
      @error = result.error
      @chosen = names.map { |name| name.to_s.strip }
      load_hackatime_options
      render :link, status: :unprocessable_content
    end
  end

  def destroy
    unless @project.deletable?
      return redirect_to(projects_path, alert: "#{@project.name} has a ship waiting or approved, so it can't be deleted. Archive it instead.", status: :see_other)
    end

    @project.discard!
    redirect_to projects_path, notice: "#{@project.name} deleted.", status: :see_other
  end

  def activate
    if @project.make_active!
      redirect_to projects_path, notice: "#{@project.name} is now your active project.", status: :see_other
    else
      redirect_to projects_path, alert: "Unarchive #{@project.name} first to make it active.", status: :see_other
    end
  end

  def archive
    @project.archive!
    redirect_to projects_path, notice: "#{@project.name} archived. You can bring it back any time.", status: :see_other
  end

  def unarchive
    @project.unarchive!
    redirect_to projects_path, notice: "#{@project.name} is back.", status: :see_other
  end

  private

  # The list the link page offers: ok false means Hackatime could not be asked (the page then shows a typed field).
  def load_hackatime_options
    options = Hackatime::ProjectNames.for(current_user)
    @options_ok = options.ok?
    @options = options.names
  end

  def set_project
    @project = current_user.projects.find(params[:id])
  end

  # status, active and guide_key are never taken from the form: they change only through the member actions above.
  def project_params
    raw = params[:project]
    attrs = raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new
    attrs.permit(:name, :kind, :idea, :repo_url, :demo_url)
  end
end
