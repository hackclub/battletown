# The emails of the notification outbox (Notifications::Email). One action per kind in Notifications::Email::KINDS;
# the action name is the kind. Called with `NotificationMailer.with(user:, kind:, values:).<kind>` where `values` are
# the one-line, already shortened facts the template needs (Notifications::Email::Content).
#
# Plain multipart (text and a small HTML part), no images, no tracking pixels, no tracked links: every link is an
# address on the app itself. Every message carries the reason it was sent, a one-click unsubscribe (the footer link
# and the RFC 8058 `List-Unsubscribe` / `List-Unsubscribe-Post` headers, both aimed at the same signed address) and the
# Hack Club program note.
#
# Flag gate: with the Flipper flag `email` off no message is built at all, whoever calls this.
class NotificationMailer < ApplicationMailer
  Notifications::Email::KINDS.each do |kind|
    define_method(kind) { build_message(kind) }
  end

  private

  def build_message(kind)
    return unless Notifications::Email.enabled?

    user = params.fetch(:user)
    @values = params.fetch(:values)
    @unsubscribe_url = Notifications::Links.email_unsubscribe(Notifications::Email::UnsubscribeToken.generate(user))
    @settings_url = Notifications::Links.settings
    headers["List-Unsubscribe"] = "<#{@unsubscribe_url}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    mail(to: user.email, subject: Notifications::Email::Config.current.subject(kind, @values), template_name: kind)
  end
end
