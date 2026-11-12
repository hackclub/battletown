module Settings
  # /settings/notifications: which Slack messages Battletown may send. A plain form (no JavaScript needed). Signed in
  # and onboarded only; it only ever reads and changes the signed-in person's own switches (there is no user id in
  # the request). Turning the daily reminder back on queues it again right away.
  class NotificationsController < ApplicationController
    before_action :require_login, :require_onboarded
    before_action :no_store

    def show
      @settings = Notifications::Preferences.settings(current_user)
      @config = Notifications::Config.current
    end

    def update
      Notifications::Preferences.update!(current_user, choices)
      Notifications::Scheduler.refresh(current_user)
      redirect_to settings_notifications_path, notice: "Saved. Your message settings are up to date.", status: :see_other
    end

    private

    # { kind => "0" | "1" }; anything else in the request is dropped.
    def choices
      raw = params[:preferences]
      return {} unless raw.is_a?(ActionController::Parameters)

      raw.permit(*Notification::KINDS).to_h
    end

    def no_store
      response.headers["Cache-Control"] = "no-store"
    end
  end
end
