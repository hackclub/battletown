class ProjectsController < ApplicationController
  before_action :require_login, :require_onboarded
  # Every project lookup goes through current_user.projects: someone else's id is a plain 404.
  before_action :set_project, only: %i[edit update destroy activate archive unarchive]

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

  def destroy
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
