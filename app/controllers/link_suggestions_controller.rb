# Answer "is this Hackatime project yours?". Scoped to the current user's projects, so others' ids are a 404.
class LinkSuggestionsController < ApplicationController
  before_action :require_login, :require_onboarded
  before_action :set_suggestion

  def accept
    link = Projects::LinkSuggestions.accept!(@suggestion)
    redirect_back_or_to projects_path, notice: "Linked #{link.hackatime_project} to #{@project.name}.", status: :see_other
  rescue Projects::LinkSuggestions::NotPending
    redirect_back_or_to projects_path, notice: "You already answered that one.", status: :see_other
  rescue ActiveRecord::RecordInvalid
    redirect_back_or_to projects_path, alert: "#{@suggestion.hackatime_project} is already linked to one of your projects.", status: :see_other
  end

  def decline
    Projects::LinkSuggestions.decline!(@suggestion)
    redirect_back_or_to projects_path, notice: "Okay, we won't ask about #{@suggestion.hackatime_project} again.", status: :see_other
  rescue Projects::LinkSuggestions::NotPending
    redirect_back_or_to projects_path, notice: "You already answered that one.", status: :see_other
  end

  private

  def set_suggestion
    @project = current_user.projects.find(params[:project_id])
    @suggestion = @project.link_suggestions.find(params[:id])
  end
end
