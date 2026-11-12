module Admin
  # Append a private staff note to a person (staff only; notes cannot be edited or deleted). The text is not copied into the audit trail.
  class UserNotesController < BaseController
    include AdminUserScoped

    def create
      AdminUsers::AddNote.call(staff: current_user, user: @user, body: params[:note].to_s)
      redirect_to admin_user_path(@user, anchor: "notes"), notice: "Note added.", status: :see_other
    rescue AdminUsers::AddNote::Invalid => error
      redirect_to admin_user_path(@user, anchor: "notes"), alert: error.message, status: :see_other
    end
  end
end
