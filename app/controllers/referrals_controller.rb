class ReferralsController < ApplicationController
  def show
    referral = Referral.find(params[:ref])
    raise ActionController::RoutingError, "Not Found" unless referral

    session[:referral_source] ||= referral.slug unless signed_in?
    redirect_to root_path
  end
end
