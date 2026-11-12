# Opening and accepting an invite link (/team/join/<token>). Signed in and onboarded only. The page names the inviter's
# display name only here, after the person chose to open the link while signed in, and says exactly what a crew shares.
# An unknown, expired or replaced token is one and the same plain "link does not work" 404, so the page never says which crews
# exist; tokens are random 96-bit values, found by exact match, and the pages are never cached or indexed.
class TeamJoinsController < ApplicationController
  before_action { require_feature!(:team) }
  before_action :require_login, :require_onboarded
  before_action :set_no_store
  before_action :set_team

  def show
    return redirect_to(team_path, notice: "You are already in this crew.") if own_crew?

    load_state
  end

  def create
    Teams::Crew.join!(user: current_user, token: params[:token])
    redirect_to team_path, notice: "You joined the crew."
  rescue Teams::Crew::InviteInvalid
    invalid_link
  rescue Teams::Crew::Error => error
    load_state
    @error = error.message
    render :show, status: :unprocessable_content
  end

  private

  def set_team
    @team = Teams::Crew.find_by_token(params[:token])
    return invalid_link unless @team&.invite_active?

    @inviter = @team.founder
    invalid_link unless @inviter # a crew nobody is in any more (about to be swept)
  end

  def invalid_link
    render :invalid, status: :not_found
  end

  def set_no_store
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Robots-Tag"] = "noindex"
  end

  def own_crew? = TeamMembership.exists?(user_id: current_user.id, team_id: @team.id)

  def load_state
    @member_count = @team.memberships.count
    @current_crew = TeamMembership.exists?(user_id: current_user.id)
    @cooldown = TeamCooldown.find_by(user_id: current_user.id)
    @cooldown = nil if @cooldown && @cooldown.ends_at <= Time.current
  end
end
