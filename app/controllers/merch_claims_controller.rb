# Claims a week's reward (flag `merch_track`). POST only (CSRF-protected like every form), idempotent per person and
# boss week: claiming twice shows the same claim, never a second one. The boss is found by id (an unknown id is a 404);
# whether this person may claim it is MerchTrack::Claim's call, and a refusal comes back as a friendly message.
class MerchClaimsController < ApplicationController
  before_action :require_login, :require_onboarded
  before_action { require_feature!(:merch_track) }

  def create
    boss = Boss.find_by(id: params[:boss_id]) or raise ActionController::RoutingError, "Not Found"
    result = MerchTrack::Claim.call(user: current_user, boss: boss)
    notice = result.created ? "Claimed: #{result.claim.item_name}. The team will message you on Slack to arrange delivery." : "You've already claimed this reward."
    redirect_to back_path, notice: notice
  rescue MerchTrack::Error => error
    redirect_to back_path, alert: error.message
  end

  private

  # Back to the page the button was on (a fixed list, never a client-supplied URL).
  def back_path = params[:from] == "dashboard" ? dashboard_path : merch_path
end
