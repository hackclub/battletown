class ApplicationController < ActionController::Base
  include FeatureFlags
  include Analytics::Controller

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # A controller can opt a request out (`skip_browser_check?`): the email unsubscribe POST comes from mail providers
  # whose user agents are not browsers at all.
  allow_browser versions: :modern, unless: :skip_browser_check?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_user, :signed_in?

  private

  def skip_browser_check? = false

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = User.find_by(id: session[:user_id]) if session[:user_id]
    reset_session if session[:user_id] && @current_user.nil?
    @current_user
  end

  def signed_in? = current_user.present?

  # Fixation-safe: always start a fresh session before attaching the user.
  # The analytics visit token survives the reset (and is stamped with the person), so the trail before sign-up is theirs.
  def sign_in(user)
    previous_token = analytics_token
    reset_session
    session[:user_id] = user.id
    @current_user = user
    analytics_link_visit(user, previous_token)
  end

  def require_login
    redirect_to root_path, alert: "Sign up with Hack Club to continue." unless signed_in?
  end

  def require_onboarded
    redirect_to onboarding_path unless current_user.onboarded?
  end
end
