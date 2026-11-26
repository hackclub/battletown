# The one Settings page (GET /settings): Notifications, Hackatime and Profile, each a section with its own anchor. A plain page (no
# JavaScript needed). Signed in and onboarded only; it only ever reads and changes the signed-in person's own choices (there is no
# user id in any request). The notification switches are saved by Settings::NotificationsController (PATCH /settings/notifications),
# the Hackatime connection by HackatimeConnectionsController (POST /auth/hackatime, DELETE /hackatime) and the profile by
# #update_profile below; each goes back to its own section of this page.
#
# With the Flipper flag `email` on the notifications section also holds the email switches (one per emailed kind, and "no email at
# all"); with it off nothing about email is shown.
class SettingsController < ApplicationController
  before_action :require_login, :require_onboarded
  before_action :no_store

  def show
    load_page
  end

  # The display name and "Use my Slack name and picture". Every player has a profile; this only chooses what it shows. A blank name
  # goes back to the default (the Slack name, else the generated handle).
  def update_profile
    user = current_user
    user.profile_name = params[:profile_name].to_s if params.key?(:profile_name)
    if user.save
      save_slack_choice(user)
      refresh_stage
      track_event(:settings_saved, section: "profile")
      redirect_to settings_path(anchor: "profile"), notice: "Saved. Other players see you as #{user.public_name}.", status: :see_other
    else
      load_page
      render :show, status: :unprocessable_content
    end
  end

  private

  # "Use my Slack name and picture" (SlackProfiles::Choice). Never fails the save: a problem here only means the Slack copy is not updated.
  def save_slack_choice(user)
    use = params[:use_slack].to_s == "1" if params.key?(:use_slack)
    SlackProfiles::Choice.set(user, use_slack: use) if !use.nil? && use != SlackProfiles::Choice.use_slack?(user)
    SlackProfiles.refresh_later(user)
  rescue StandardError => error
    Rails.logger.warn("Settings: Slack profile choice not saved (#{error.class})")
  end

  # The boss stage caches who is fighting for 20 seconds: drop that snapshot so a changed name or picture shows at once, then push.
  # Never fails the save.
  def refresh_stage
    boss = Bosses::Live.current_boss
    Bosses::Fighters.forget_for(boss) if boss
    Bosses::Live.hours_changed
  rescue StandardError => error
    Rails.logger.warn("Settings: boss stage not refreshed (#{error.class})")
  end

  def load_page
    @connection = current_user.hackatime_connection
    @settings = Notifications::Preferences.visible_settings(current_user)
    @config = Notifications::Config.current
    load_email_settings
  end

  def load_email_settings
    return unless feature?(:email)

    @email_settings = Notifications::Preferences.visible_settings(current_user, channel: Notifications::Preferences::EMAIL)
    @email_config = Notifications::Email::Config.current
    @email_on = !current_user.email_opted_out?
    @email_address_ok = Notifications::Email.valid_address?(current_user.email)
  end

  def no_store
    response.headers["Cache-Control"] = "no-store"
  end
end
