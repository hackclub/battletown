class SessionsController < ApplicationController
  # Dev login exists only in development (the action 404s anywhere else) and logs in a fixed fake user, so a stale CSRF
  # token (a cached page, or a session cookie overwritten by another local server) must not block it. Real sign-in
  # keeps OmniAuth's CSRF check.
  skip_before_action :verify_authenticity_token, only: :dev_login if Rails.env.development?

  # Signup and login are the same flow: the first Hack Club Auth callback creates the user.
  def create
    claims = hca_claims(request.env["omniauth.auth"])
    return failure unless claims

    user = User.from_hca_claims!(claims, referral_source: session[:referral_source], draft: OnboardingDraft.new(session))
    Notifications::Scheduler.refresh(user) if user.saved_change_to_slack_id?
    sign_in(user)
    redirect_after_sign_in(user)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Sign-in failed to save user: #{e.record.errors.full_messages.to_sentence}")
    failure
  end

  def failure
    return hackatime_failure if params[:strategy].to_s == "hackatime"
    return address_failure if params[:strategy].to_s == "hack_club_address"

    Rails.logger.warn("Auth failure: #{params[:message].to_s.truncate(60).inspect}")
    if params[:message].to_s == "access_denied"
      # They pressed Deny on the Hack Club Auth consent screen: that is a choice, not an error.
      redirect_to root_path, notice: "No problem, you didn't sign in. You can join whenever you're ready."
    else
      redirect_to root_path, alert: "We couldn't sign you in. Please try again."
    end
  end

  # The page between the two sign-ins. It exists only straight after a Hack Club sign-in (the session flag is used up
  # here), so a reload or a link goes on to where the person belongs instead. Its form posts itself to Hackatime's OAuth.
  def hackatime_step
    chained = session.delete(:hackatime_step)
    return redirect_to root_path unless signed_in?
    return redirect_to(current_user.onboarded? ? dashboard_path : onboarding_path) unless chained

    # The callback reads this to carry on to the right place (HackatimeConnectionsController).
    session[:hackatime_chain] = true
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out.", status: :see_other
  end

  # Development only, so the app is usable without Hack Club Auth credentials.
  def dev_login
    return head :not_found unless Rails.env.development?

    claims = { "sub" => "dev-user", "name" => "Dev User", "email" => "dev@example.com", "verification_status" => "verified", "ysws_eligible" => true }
    user = User.from_hca_claims!(claims, referral_source: session[:referral_source], draft: OnboardingDraft.new(session))
    sign_in(user)
    redirect_after_sign_in(user)
  end

  private

  # A failed Hackatime link (bad state, denied consent, ...) is not a sign-in failure: send them back to the
  # Hackatime page, never to the landing page, and never touch their session.
  # The onboarding account step for someone still onboarding; for someone who is in, the dashboard if the chain started
  # this (they never asked to be on the Hackatime page) and the Hackatime page otherwise.
  def hackatime_return_path(chained = false)
    return onboarding_step_path("account") unless current_user.onboarded?

    chained ? dashboard_path : hackatime_path
  end

  def hackatime_failure
    chained = session.delete(:hackatime_chain)
    message = params[:message].to_s
    Rails.logger.warn("Hackatime link failure: #{message.truncate(40).inspect}")
    return redirect_to root_path, alert: "Sign in to connect Hackatime." unless signed_in?

    if message == "access_denied"
      notice = current_user.onboarded? ? "No problem, Hackatime wasn't connected. You can connect whenever you're ready." : "Hackatime wasn't connected. You need it to finish signing up, so connect when you're ready."
      redirect_to hackatime_return_path(chained), notice: notice
    else
      redirect_to hackatime_return_path(chained), alert: "We couldn't connect to Hackatime. Please try again."
    end
  end

  # A failed or refused address lookup (bad state, denied consent, no one signed in ...) is not a sign-in failure either: send them back
  # to the page they started from (or the shop), and keep nothing. Pressing Deny is a choice, not an error.
  def address_failure
    message = params[:message].to_s
    Rails.logger.warn("Address lookup failure: #{message.truncate(40).inspect}")
    return redirect_to root_path, alert: "Sign in to order from the shop." unless signed_in?

    context = Orders::AddressLookup.consume(session)
    target = context ? Orders::AddressLookup.return_path(context) : shop_path
    if message == "access_denied"
      redirect_to target, notice: "No problem, nothing was loaded. We need an address from Hack Club Auth to post your prize; you can do this whenever you're ready."
    else
      redirect_to target, alert: "We couldn't load your addresses from Hack Club Auth, so nothing was saved. Please try again."
    end
  end

  def hca_claims(auth)
    return unless auth && auth.provider.to_s == "hack_club" && auth.uid.present?

    auth.extra&.raw_info.to_h.stringify_keys.merge("sub" => auth.uid)
  end

  def redirect_after_sign_in(user)
    if hackatime_chain?(user)
      session[:hackatime_step] = true
      redirect_to sign_in_hackatime_path
    else
      redirect_to user.onboarded? ? dashboard_path : onboarding_path
    end
  end

  # Someone with no working Hackatime link goes on to Hackatime straight after signing in (config.x.hackatime.sign_in_chain).
  def hackatime_chain?(user)
    return false unless Rails.configuration.x.hackatime.sign_in_chain

    connection = user.hackatime_connection
    connection.nil? || connection.needs_reconnect?
  end
end
