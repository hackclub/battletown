# Development-only mail previews: http://localhost:3000/rails/mailers/notification_mailer (Rails mounts previews in
# development only). Made-up facts and a made-up person on a reserved domain: no database rows are read or written and
# nothing is sent. The mailer builds nothing while the Flipper flag `email` is off, so enable it in the development
# database first (`bin/rails runner 'Flipper.enable(:email)'`).
class NotificationMailerPreview < ActionMailer::Preview
  def ship_approved
    mailer(project: "Space Farm", hours: "3", coins: 120, locked: true, verify_url: ShopHelper::VERIFY_URL,
           link: Notifications::Links.projects).ship_approved
  end

  def ship_rejected
    mailer(project: "Space Farm", reason: "The demo link does not open.", link: Notifications::Links.projects).ship_rejected
  end

  def returning_nudge
    mailer(boost_days: 3, link: Notifications::Links.dashboard).returning_nudge
  end

  private

  def mailer(values)
    user = User.new(id: 0, email: "preview@example.test", email_unsubscribe_nonce: "preview-nonce")
    NotificationMailer.with(user: user, values: values)
  end
end
