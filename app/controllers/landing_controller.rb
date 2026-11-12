class LandingController < ApplicationController
  def show
    return redirect_to dashboard_path if signed_in? && current_user.onboarded?

    @referral = Referral.find(session[:referral_source])
    @prizes = Prize.paid.sort_by(&:coins)
  end
end
