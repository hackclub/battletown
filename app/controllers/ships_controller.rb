# A teen's own ships: the form (per project), the list, one ship, withdraw. Signed in and onboarded only; every ship
# and project lookup goes through current_user, so someone else's id is a plain 404. Coding is never blocked here:
# when a project cannot be shipped yet the page says why and what to do next.
class ShipsController < ApplicationController
  before_action :require_login, :require_onboarded
  before_action :set_project, only: %i[new create]
  before_action :set_ship, only: %i[show edit update withdraw]
  before_action :require_draft, only: %i[edit update]

  def index
    @ships = current_user.ships.includes(:project, :coin_transactions).newest_first
  end

  def show
    @breakdown = @ship.coin_breakdown if @ship.status_approved?
  end

  def new
    @carry_ship = carry_source
    open = @project.ships.open_now.first
    return redirect_to(open_ship_path(open), notice: "This project already has a ship in progress.") if open

    @ship = @project.ships.build(user: current_user, repo_url: @project.repo_url, demo_url: @project.demo_url)
    prefill_from_rejected
    load_window
  end

  def create
    submit_and_respond(nil)
  end

  def edit
    @project = @ship.project
    load_window
  end

  def update
    @project = @ship.project
    submit_and_respond(@ship)
  end

  def withdraw
    if Ships::Withdraw.call(ship: @ship)
      redirect_to ships_path, notice: "Ship withdrawn. The hours you coded are free for your next ship.", status: :see_other
    else
      redirect_to ship_path(@ship), alert: "This ship has already been decided, so it can't be withdrawn.", status: :see_other
    end
  end

  private

  def set_project = @project = current_user.projects.find(params[:project_id])

  def set_ship = @ship = current_user.ships.includes(:project).find(params[:id])

  def require_draft
    redirect_to ship_path(@ship), alert: "Only a draft can be edited." unless @ship.status_draft?
  end

  def open_ship_path(ship) = ship.status_draft? ? edit_ship_path(ship) : ship_path(ship)

  def ship_params
    raw = params[:ship]
    (raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new).permit(:description, :repo_url, :demo_url)
  end

  # The form has two buttons: "Save draft" sends ship_action=draft, "Submit ship" anything else.
  def submitting? = params[:ship_action].to_s != "draft"

  def submit_and_respond(ship)
    submitting = submitting?
    @carry_ship = carry_source
    plan = image_plan(ship)
    return render_image_errors(ship, plan) if plan&.errors?

    after_save = plan&.changes? ? ->(saved_ship) { plan.commit!(saved_ship) } : nil
    saved = Ships::Submit.call(project: @project, ship: ship, attributes: ship_params, submit: submitting, after_save: after_save)
    if saved.persisted? && saved.errors.empty?
      notice = submitting ? "Ship submitted. A staff member will review it." : "Draft saved."
      redirect_to ship_path(saved), notice: notice, status: :see_other
    else
      @ship = saved
      load_window
      render(ship ? :edit : :new, status: :unprocessable_content)
    end
  rescue Ships::Submit::AlreadyOpen => error
    redirect_to open_ship_path(error.ship), notice: "This project already has a ship in progress.", status: :see_other
  rescue Ships::Submit::Refused
    @ship = ship || @project.ships.build(user: current_user, **ship_params.to_h.symbolize_keys)
    load_window
    render(ship ? :edit : :new, status: :unprocessable_content)
  end

  # Screenshots (flag `ship_screenshots`; with it off the upload fields are never read, so nothing is stored).
  # Every file is checked and re-encoded before the ship is saved: a bad one shows its message and saves nothing.
  def image_plan(ship)
    return unless feature?(:ship_screenshots)

    ShipImages::Plan.build(params: params[:images], ship: ship, carry_from: @carry_ship)
  end

  # "Fix and ship again": the rejected ship (the teen's own, in this project) whose screenshots are offered again.
  def carry_source
    return unless feature?(:ship_screenshots) && params[:from].present? && %w[new create].include?(action_name)

    @project.ships.find_by(id: params[:from], status: "rejected")
  end

  def render_image_errors(ship, plan)
    @ship = ship || @project.ships.build(user: current_user)
    @ship.assign_attributes(ship_params)
    plan.errors.each { |message| @ship.errors.add(:base, message) }
    load_window
    render(ship ? :edit : :new, status: :unprocessable_content)
  end

  # What the form says: how much can be shipped and, if nothing can yet, why.
  def load_window
    @window = Ships::Window.call(@project)
    @min_seconds = Ships::Config.current.min_seconds
    @readiness = readiness
    @previous_ship = @project.ships.where(status: Ship::WINDOW_STATUSES).where.not(id: @ship&.id).order(:window_end_date).last
  end

  def readiness
    return :no_link unless @project.hackatime_links.exists?
    return :no_hours if @window.empty?

    @window.seconds < @min_seconds ? :too_few : :ready
  end

  # "Fix and ship again": the description and links of the ship that was turned down (only the user's own).
  def prefill_from_rejected
    rejected = @project.ships.find_by(id: params[:from], status: "rejected")
    return unless rejected

    @ship.assign_attributes(description: rejected.description, repo_url: rejected.repo_url, demo_url: rejected.demo_url)
  end
end
