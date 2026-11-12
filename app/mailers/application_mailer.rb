# Base class for Battletown's email. The sender is the MAIL_FROM environment variable (see config/email_transport.rb).
# Nothing mails anyone from here directly: Notifications::Email::MailerAdapter does, from the notification outbox.
class ApplicationMailer < ActionMailer::Base
  default from: -> { EmailTransport.sender }
  layout "mailer"
end
