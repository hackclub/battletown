# Reads config/account.yml.
module AccountSettings
  def self.config = Rails.application.config_for(:account)

  def self.recent_login_window = config.fetch(:recent_login_minutes).to_i.minutes

  def self.delete_phrase = config.fetch(:delete_phrase).to_s
end
