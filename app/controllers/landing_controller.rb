class LandingController < ApplicationController
  # The hero only says "Join N other fighters" once N is over this many.
  FIGHTERS_LINE_MIN = 50

  def show
    return redirect_to dashboard_path if signed_in? && current_user.onboarded?

    track_event(:landing_viewed)
    @referral = Referral.find(session[:referral_source])
    @prizes = Prize.paid
    onboarded = User.onboarded.count
    @onboarded_fighters = onboarded if onboarded > FIGHTERS_LINE_MIN
  end
end
