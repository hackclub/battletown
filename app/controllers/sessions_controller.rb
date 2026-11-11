class SessionsController < ApplicationController
  # Signup and login are the same flow: the first Hack Club Auth callback creates the user.
  def create
    claims = hca_claims(request.env["omniauth.auth"])
    return failure unless claims

    user = User.from_hca_claims!(claims, referral_source: session[:referral_source])
    sign_in(user)
    redirect_after_sign_in(user)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Sign-in failed to save user: #{e.record.errors.full_messages.to_sentence}")
    failure
  end

  def failure
    Rails.logger.warn("Auth failure: #{params[:message].to_s.truncate(60).inspect}")
    redirect_to root_path, alert: "We couldn't sign you in. Please try again."
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out.", status: :see_other
  end

  # Development only, so the app is usable without Hack Club Auth credentials.
  def dev_login
    return head :not_found unless Rails.env.development?

    claims = { "sub" => "dev-user", "name" => "Dev User", "email" => "dev@example.com", "verification_status" => "verified" }
    user = User.from_hca_claims!(claims, referral_source: session[:referral_source])
    sign_in(user)
    redirect_after_sign_in(user)
  end

  private

  def hca_claims(auth)
    return unless auth && auth.provider.to_s == "hack_club" && auth.uid.present?

    auth.extra&.raw_info.to_h.stringify_keys.merge("sub" => auth.uid)
  end

  def redirect_after_sign_in(user)
    redirect_to user.onboarded? ? dashboard_path : onboarding_path
  end
end
