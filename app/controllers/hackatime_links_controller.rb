# Link or unlink a Hackatime project by typing its exact name. Only ever acts on the current user's own projects.
class HackatimeLinksController < ApplicationController
  before_action :require_login, :require_onboarded
  before_action :set_project

  def create
    name = hackatime_project_param
    link = @project.hackatime_links.build(user: current_user, hackatime_project: name, link_method: "manual")
    if link.save
      # A pending question about the same name is answered by typing it yourself.
      @project.link_suggestions.pending.where(hackatime_project: link.hackatime_project).update_all(state: "accepted", updated_at: Time.current)
      redirect_to edit_project_path(@project), notice: "Linked #{link.hackatime_project}.", status: :see_other
    else
      redirect_to edit_project_path(@project), alert: friendly_error(link, name), status: :see_other
    end
  end

  def destroy
    link = @project.hackatime_links.find(params[:id])
    HackatimeLink.transaction do
      link.destroy!
      Projects::LinkSuggestions.remember_decline!(@project, link.hackatime_project)
    end
    redirect_to edit_project_path(@project), notice: "Unlinked #{link.hackatime_project}.", status: :see_other
  end

  private

  def set_project
    @project = current_user.projects.find(params[:project_id])
  end

  def hackatime_project_param
    value = params[:hackatime_link]
    (value.is_a?(ActionController::Parameters) ? value : ActionController::Parameters.new).permit(:hackatime_project)[:hackatime_project].to_s.strip
  end

  def friendly_error(link, name)
    errors = link.errors
    if name.blank?
      "Type the name of the Hackatime project to link."
    elsif errors.of_kind?(:hackatime_project, :taken)
      other = HackatimeLink.project_for(current_user, name)
      other ? "#{name} is already linked to #{other.name}. Unlink it there first." : "#{name} is already linked."
    else
      "Couldn't link that: #{errors.full_messages.to_sentence}."
    end
  end
end
