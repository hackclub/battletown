# Self-service account page, data export and deletion. Everything acts on current_user: no action
# reads a user id from the request.
class AccountsController < ApplicationController
  before_action :require_login
  before_action :no_store
  before_action -> { require_recent_login("export") }, only: :export
  before_action -> { require_recent_login("delete") }, only: %i[confirm_delete destroy]

  def show
  end

  def export
    send_data AccountExport.new(current_user).to_json,
      filename: "battletown-data-export-#{Time.current.utc.strftime("%Y%m%d")}.json",
      type: "application/json", disposition: "attachment"
  end

  # The "sign in again to confirm" step. Where it returns to was stored server-side by require_recent_login.
  def reauth
    redirect_to account_path unless pending_reauth
  end

  def confirm_delete
  end

  def destroy
    unless params[:confirmation].to_s.strip == AccountSettings.delete_phrase
      flash.now[:alert] = "That didn't match, so nothing was deleted."
      return render :confirm_delete, status: :unprocessable_content
    end

    AccountDeletion.call(current_user)
    reset_session
    redirect_to root_path, notice: "Your Battletown account and the data we stored have been deleted.", status: :see_other
  end

  private

  # These pages and the export contain personal data: never let a browser or proxy keep a copy.
  def no_store
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
  end
end
