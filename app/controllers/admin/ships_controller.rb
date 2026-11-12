module Admin
  # The staff review queue: waiting ships first (oldest first), a status filter, one ship with its context, and the
  # approve / reject decisions. A ship that is not waiting any more (withdrawn, or decided by another admin) is
  # reported, never changed. Drafts are the teen's own and are never listed.
  class ShipsController < BaseController
    FILTERS = %w[submitted approved rejected withdrawn].freeze
    LIMIT = 100

    before_action :set_ship, only: %i[show approve reject]

    def index
      @status = params[:status].to_s.presence_in(FILTERS)
      scope = visible.includes(:user, :project)
      scope = scope.where(status: @status) if @status
      @ships = scope.review_order.limit(LIMIT).to_a
      @counts = visible.group(:status).count
    end

    def show
      load_context
    end

    def approve
      seconds = Ships::Approve.seconds_from_hours(@ship, params[:approved_hours])
      result = Ships::Approve.call(ship: @ship, reviewer: current_user, approved_seconds: seconds)
      if result.approved?
        redirect_to admin_ship_path(@ship), notice: approved_notice(result), status: :see_other
      else
        redirect_to admin_ship_path(@ship), alert: "This ship is no longer waiting for review, so nothing was changed.", status: :see_other
      end
    rescue Ships::Approve::Invalid => error
      redirect_to admin_ship_path(@ship), alert: error.message, status: :see_other
    end

    def reject
      reason = Ships::Reject.reason_from(preset: params[:reason_preset], note: params[:reason_note])
      result = Ships::Reject.call(ship: @ship, reviewer: current_user, reason: reason)
      if result.rejected?
        redirect_to admin_ships_path, notice: "Ship rejected. The teen can fix it and ship again.", status: :see_other
      else
        redirect_to admin_ship_path(@ship), alert: "This ship is no longer waiting for review, so nothing was changed.", status: :see_other
      end
    rescue Ships::Reject::Invalid => error
      redirect_to admin_ship_path(@ship), alert: error.message, status: :see_other
    end

    private

    def visible = Ship.where.not(status: "draft")

    def set_ship = @ship = visible.includes(:user, :project, :reviewer).find(params[:id])

    def load_context
      @unsettled = Ships::Approve.unsettled_dates(@ship)
      @links = @ship.project.hackatime_links.order(:id).pluck(:hackatime_project)
      @previous = visible.where(user_id: @ship.user_id).where.not(id: @ship.id).includes(:project).order(submitted_at: :desc, id: :desc).limit(10)
      @streak = DailyResult.where(user_id: @ship.user_id).chronological.last
      @breakdown = @ship.coin_breakdown if @ship.status_approved?
    end

    def approved_notice(result)
      credit = result.credit
      "Approved. Credited #{credit.base_coins} coins plus #{credit.bonus_coins} streak bonus coins."
    end
  end
end
