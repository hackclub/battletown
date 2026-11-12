# Action Mailer's own log subscriber writes the recipient and, at debug level, the whole message (headers and body) to
# the log. Battletown never logs an email address or message text (docs/CONTRACT.md, "Email notifications"), so Action
# Mailer gets a logger that goes nowhere; the app logs its own one-line "email queued kind=..." instead
# (Notifications::Email::MailerAdapter). Rails.logger is untouched.
ActiveSupport.on_load(:action_mailer) do
  self.logger = ActiveSupport::Logger.new(nil)
end
