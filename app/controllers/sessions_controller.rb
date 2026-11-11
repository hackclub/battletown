class SessionsController < ApplicationController
  # Signup and login are the same flow: the first Hack Club Auth callback creates the user.
  def create
    claims = hca_claims(request.env["omniauth.auth"])
    return failure unless claims

    authenticate(claims)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Sign-in failed to save user: #{e.record.errors.full_messages.to_sentence}")
    failure
  end

  def failure
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

    claims = { "sub" => "dev-user", "name" => "Dev User", "email" => "dev@example.com", "verification_status" => "verified" }
    authenticate(claims)
  end

  private

  # Signs in, or, when a signed-in person started a "sign in again to confirm" step (RecentLogin), checks
  # it is the SAME Hack Club account before anything is changed: a different account is refused, the
  # existing session is left alone and no user row is created for the other account.
  def authenticate(claims)
    reauth = pending_reauth
    if reauth && User.find_by(id: session[:user_id])&.hca_uid != claims["sub"]
      session.delete(:reauth)
      Rails.logger.warn("Re-sign-in refused: different account")
      return redirect_to account_path, alert: "That was a different Hack Club account, so nothing was changed. Sign in again with the account you are using here."
    end

    user = User.from_hca_claims!(claims, referral_source: session[:referral_source])
    sign_in(user)
    return redirect_after_sign_in(user) unless reauth

    redirect_to public_send(RecentLogin::REAUTH_TARGETS.fetch(reauth)), notice: "Thanks, you are signed in again."
  end

  def hca_claims(auth)
    return unless auth && auth.provider.to_s == "hack_club" && auth.uid.present?

    auth.extra&.raw_info.to_h.stringify_keys.merge("sub" => auth.uid)
  end

  def redirect_after_sign_in(user)
    redirect_to user.onboarded? ? dashboard_path : onboarding_path
  end
end
