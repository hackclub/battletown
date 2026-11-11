# "Recent login" for sensitive actions (data export, account deletion). sign_in stamps
# session[:authenticated_at]; anything older than config/account.yml `recent_login_minutes`, or a
# session from before this existed, must sign in again through Hack Club Auth first.
#
# The page to come back to is never taken from a request: only the keys of REAUTH_TARGETS can be
# stored, so there is no open redirect.
module RecentLogin
  extend ActiveSupport::Concern

  REAUTH_TARGETS = { "export" => :account_path, "delete" => :delete_account_path }.freeze

  private

  def stamp_authenticated_at
    session[:authenticated_at] = Time.current.to_i
  end

  def recent_login?
    at = session[:authenticated_at]
    at.is_a?(Integer) && within_window?(at)
  end

  def require_recent_login(target)
    return if recent_login?

    session[:reauth] = { "target" => target.to_s, "at" => Time.current.to_i }
    redirect_to reauth_account_path
  end

  # The allowlisted target of a re-sign-in the signed-in user started in the last few minutes, else nil.
  def pending_reauth
    data = session[:reauth]
    return unless session[:user_id] && data.is_a?(Hash)
    return unless REAUTH_TARGETS.key?(data["target"]) && data["at"].is_a?(Integer) && within_window?(data["at"])

    data["target"]
  end

  def within_window?(timestamp)
    age = Time.current.to_i - timestamp
    age >= 0 && age <= AccountSettings.recent_login_window.to_i
  end
end
