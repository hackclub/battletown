module Admin
  # Add or take off coded time for a person: form (new), a confirm step that shows the effect and keeps the typed reason, and
  # the write (create). See AdminUsers::HoursAdjustment for the rules. The form carries a one-time token made on the server, so
  # pressing the button twice changes the ledger once.
  class UserHoursAdjustmentsController < BaseController
    include AdminUserScoped

    def new
      @adjustment = build(direction: "add", date: Hours::Days.today(@user.time_zone).iso8601, token: AdminUsers::Adjustment.new_token)
    end

    def confirm
      @adjustment = build(adjustment_params)
      render :new, status: :unprocessable_content unless @adjustment.valid?
    end

    def create
      @adjustment = build(adjustment_params)
      return confirm_first unless params[:confirmed] == "1"

      outcome = @adjustment.apply!
      notice = outcome.duplicate? ? "That adjustment had already been applied, so nothing changed." : "Hours adjusted. The change is in the ledger and the audit trail."
      redirect_to admin_user_path(@user), notice: notice, status: :see_other
    rescue AdminUsers::Adjustment::Invalid
      render :new, status: :unprocessable_content
    end

    private

    def confirm_first
      return render(:confirm) if @adjustment.valid?

      render :new, status: :unprocessable_content
    end

    def build(attributes) = AdminUsers::HoursAdjustment.new(staff: current_user, user: @user, **attributes)

    def adjustment_params = params.permit(:direction, :date, :minutes, :reason, :token).to_h.symbolize_keys
  end
end
