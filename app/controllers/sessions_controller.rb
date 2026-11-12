class SessionsController < ApplicationController
  # Signup and login are the same flow: the first Hack Club Auth callback creates the user.
  def create
    claims = hca_claims(request.env["omniauth.auth"])
    return failure unless claims

    user = User.from_hca_claims!(claims, referral_source: session[:referral_source])
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

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out.", status: :see_other
  end

  # Development only, so the app is usable without Hack Club Auth credentials.
  def dev_login
    return head :not_found unless Rails.env.development?

    claims = { "sub" => "dev-user", "name" => "Dev User", "email" => "dev@example.com", "verification_status" => "verified", "ysws_eligible" => true }
    user = User.from_hca_claims!(claims, referral_source: session[:referral_source])
    sign_in(user)
    redirect_after_sign_in(user)
  end

  private

  # A failed Hackatime link (bad state, denied consent, ...) is not a sign-in failure: send them back to the
  # Hackatime page, never to the landing page, and never touch their session.
  def hackatime_failure
    message = params[:message].to_s
    Rails.logger.warn("Hackatime link failure: #{message.truncate(40).inspect}")
    return redirect_to root_path, alert: "Sign in to connect Hackatime." unless signed_in?

    if message == "access_denied"
      redirect_to hackatime_path, notice: "No problem, Hackatime wasn't connected. You can connect whenever you're ready."
    else
      redirect_to hackatime_path, alert: "We couldn't connect to Hackatime. Please try again."
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
    redirect_to user.onboarded? ? dashboard_path : onboarding_path
  end
end
