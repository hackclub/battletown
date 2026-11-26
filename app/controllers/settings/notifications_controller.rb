module Settings
  # Which Slack messages Battletown may send. The form lives on the Settings page (SettingsController, #notifications); this saves
  # it (PATCH /settings/notifications) and sends GET /settings/notifications (old bookmarks, the links in Slack messages and email)
  # there. A plain form (no JavaScript needed). Signed in and onboarded only; it only ever changes the signed-in person's own switches
  # (there is no user id in the request). Turning the daily reminder back on queues it again right away. With the Flipper flag `email`
  # on it also saves the email switches (one per emailed kind, and "no email at all"); with it off the email parameters are ignored.
  class NotificationsController < ApplicationController
    before_action :require_login, :require_onboarded
    before_action :no_store

    def show
      redirect_to settings_path(anchor: "notifications")
    end

    def update
      Notifications::Preferences.update!(current_user, choices)
      save_email_settings if feature?(:email)
      Notifications::Scheduler.refresh(current_user)
      track_event(:settings_saved, section: "notifications")
      redirect_to settings_path(anchor: "notifications"), notice: "Saved. Your message settings are up to date.", status: :see_other
    end

    private

    # { kind => "0" | "1" }; anything else in the request is dropped.
    def choices
      raw = params[:preferences]
      return {} unless raw.is_a?(ActionController::Parameters)

      raw.permit(*Notifications::Preferences.visible_kinds).to_h
    end

    # The per-kind email switches, then the global one ("0" unsubscribes, "1" turns email back on and rotates the
    # unsubscribe nonce, which retires every link in earlier emails).
    def save_email_settings
      raw = params[:email_preferences]
      if raw.is_a?(ActionController::Parameters)
        Notifications::Preferences.update!(current_user, raw.permit(*Notifications::Email::KINDS).to_h, Notifications::Preferences::EMAIL)
      end
      case params[:email_enabled].to_s
      when "0" then Notifications::Email::Subscription.unsubscribe!(current_user)
      when "1" then Notifications::Email::Subscription.resubscribe!(current_user)
      end
    end

    def no_store
      response.headers["Cache-Control"] = "no-store"
    end
  end
end
