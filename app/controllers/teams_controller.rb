# The signed-in person's own crew (the "team bonus", flag `team`): see it, start one, rename it, make a new invite link, leave.
# Signed in and onboarded only, and there is no id in any route: it is always the current user's crew, so nobody can open
# another crew's page. Crewmates see display names and nothing else. While the flag is off every route here is a 404.
class TeamsController < ApplicationController
  before_action { require_feature!(:team) }
  before_action :require_login, :require_onboarded

  def show
    @summary = Teams::Summary.for(current_user)
    if @summary.in_crew?
      @members = TeamMembership.where(team_id: @summary.team.id).includes(:user).order(:joined_at, :id).map(&:user)
    else
      @cooldown = TeamCooldown.find_by(user_id: current_user.id)
      @cooldown = nil if @cooldown && @cooldown.ends_at <= Time.current
    end
  end

  def create
    Teams::Crew.create!(user: current_user, name: name_param)
    redirect_to team_path, notice: "Your crew is ready. Share the invite link with a buddy."
  rescue Teams::Crew::Error, ActiveRecord::RecordInvalid => error
    redirect_to team_path, alert: friendly(error)
  end

  def update
    Teams::Crew.rename!(user: current_user, name: name_param)
    redirect_to team_path, notice: "Crew name saved."
  rescue Teams::Crew::Error, ActiveRecord::RecordInvalid => error
    redirect_to team_path, alert: friendly(error)
  end

  def invite
    Teams::Crew.regenerate_invite!(user: current_user)
    redirect_to team_path, notice: "Here is a new invite link. The old one does not work any more."
  rescue Teams::Crew::Error => error
    redirect_to team_path, alert: error.message
  end

  def leave
    Teams::Crew.leave!(user: current_user)
    redirect_to team_path, notice: "You left the crew. Coins you already earned stay yours.", status: :see_other
  rescue Teams::Crew::Error => error
    redirect_to team_path, alert: error.message, status: :see_other
  end

  private

  def name_param = params.dig(:team, :name).to_s

  def friendly(error)
    return error.message if error.is_a?(Teams::Crew::Error)

    "The crew name can be up to #{Team::NAME_MAX} characters, with no special control characters."
  end
end
