# Saves the dashboard's to-do boxes (up to three short items on the active project). Only the person's own project is ever
# read or written; nothing here is logged (the `todos` params are filtered).
class DashboardTodosController < ApplicationController
  before_action :require_login, :require_onboarded

  def update
    project = current_user.active_project
    return no_project unless project

    project.todos = Project.clean_todos(params[:todos])
    if project.save
      track_todo_use(project)
      respond_to do |format|
        format.html { redirect_to dashboard_path, status: :see_other }
        format.json { head :no_content } # the page saves in the background (todo-autosave) and needs nothing back
      end
    else
      respond_to do |format|
        format.html { redirect_to dashboard_path, alert: "We couldn't save your list. Please try again.", status: :see_other }
        format.json { head :unprocessable_content }
      end
    end
  end

  private

  # The page autosaves, so a day with a list counts once (the number of items on the first save of the day that had any).
  def track_todo_use(project)
    return if project.todos.empty?

    track_event(:todo_used, items: project.todos.size, once: "todo:#{Hours::Days.today(current_user).iso8601}")
  end

  def no_project
    respond_to do |format|
      format.html { redirect_to dashboard_path, alert: "Add a project first, then you can plan what to do on it." }
      format.json { head :unprocessable_content }
    end
  end
end
