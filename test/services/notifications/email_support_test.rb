require "test_helper"
require_relative "../../support/email_helper"

# The small parts of the email channel: transport settings from the environment, the unsubscribe token, the global
# switch, the adapter's error mapping and its logging, and the config.
class Notifications::EmailSupportTest < ActiveSupport::TestCase
  include EmailHelper

  setup { @user = create_email_user("sup1") }

  # --- EmailTransport (config/email_transport.rb) ---

  test "there is no SMTP transport unless SMTP_ADDRESS and MAIL_FROM are both set" do
    assert_nil EmailTransport.smtp_settings({})
    assert_nil EmailTransport.smtp_settings({ "SMTP_ADDRESS" => "smtp.example.test" })
    assert_nil EmailTransport.smtp_settings({ "MAIL_FROM" => "Battletown <b@example.test>" })
    assert_not EmailTransport.configured?({ "SMTP_ADDRESS" => " ", "MAIL_FROM" => "x@example.test" })
  end

  test "credentials must come as a pair, the port defaults to 587 and 465 means implicit TLS" do
    base = { "SMTP_ADDRESS" => "smtp.example.test", "MAIL_FROM" => "Battletown <b@example.test>" }
    assert_nil EmailTransport.smtp_settings(base.merge("SMTP_USERNAME" => "u"))
    assert_nil EmailTransport.smtp_settings(base.merge("SMTP_PASSWORD" => "p"))

    open_relay = EmailTransport.smtp_settings(base)
    assert_equal [ "smtp.example.test", 587, :always ], [ open_relay[:address], open_relay[:port], open_relay[:enable_starttls] ]
    assert_not open_relay.key?(:user_name)

    authed = EmailTransport.smtp_settings(base.merge("SMTP_USERNAME" => "u", "SMTP_PASSWORD" => "p", "SMTP_DOMAIN" => "example.test", "SMTP_PORT" => "465"))
    assert_equal [ 465, "u", :plain, "example.test", true ], [ authed[:port], authed[:user_name], authed[:authentication], authed[:domain], authed[:tls] ]
    assert_equal 587, EmailTransport.smtp_settings(base.merge("SMTP_PORT" => "abc"))[:port]
  end

  test "the sender is MAIL_FROM or a placeholder on a reserved domain" do
    assert_equal "Battletown <b@example.test>", EmailTransport.sender({ "MAIL_FROM" => " Battletown <b@example.test> " })
    assert_equal EmailTransport::DEFAULT_FROM, EmailTransport.sender({})
    assert_includes EmailTransport::DEFAULT_FROM, "@example.com"
  end

  test "the test suite and development never use a real transport" do
    assert_equal :test, ActionMailer::Base.delivery_method
    assert_not Notifications::Email::MailerAdapter.new.delivers?
    assert_nil ActionMailer::Base.smtp_settings[:user_name]
    assert_equal Rails.root.join("config/environments/development.rb").read[/delivery_method = :(\w+)/, 1], "test"
  end

  test "production uses SMTP only through EmailTransport, and otherwise delivers nothing" do
    source = Rails.root.join("config/environments/production.rb").read
    assert_match(/if \(smtp = EmailTransport\.smtp_settings\)/, source)
    assert_match(/delivery_method = :smtp/, source)
    assert_match(/else\s+config\.action_mailer\.delivery_method = :test\s+config\.action_mailer\.perform_deliveries = false/m, source)
    assert_no_match(/smtp_settings = \{/, source, "no literal SMTP settings in the repository")
  end

  # --- the adapter ---

  test "the adapter only claims delivery on a real SMTP transport that is switched on" do
    adapter = Notifications::Email::MailerAdapter.new
    original = [ ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries ]
    begin
      ActionMailer::Base.delivery_method = :smtp
      ActionMailer::Base.perform_deliveries = true
      assert adapter.delivers?
      ActionMailer::Base.perform_deliveries = false
      assert_not adapter.delivers?
    ensure
      ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries = original
    end
  end

  test "the adapter logs one line with the kind and never the address, subject or body" do
    values = { project: "Space Farm", hours: "3", coins: 10, locked: false, verify_url: "https://example.test/v", link: "https://example.test/ships/1" }
    logs = capture_logs { with_feature(:email) { Notifications::Email::MailerAdapter.new.deliver(user: @user, kind: "ship_approved", values: values) } }
    assert_includes logs, "notifications.email queued kind=ship_approved"
    assert_not_includes logs, @user.email
    assert_not_includes logs, "Space Farm"
    assert_not_includes logs, "Good news"
  end

  test "Action Mailer's own logger goes nowhere (config/initializers/mailer_privacy.rb), so no address or message reaches any log" do
    assert_nil ActionMailer::Base.logger.instance_variable_get(:@logdev)
    logs = capture_logs { with_feature(:email) { NotificationMailer.with(user: @user, values: { boost_days: 3, link: "https://example.test/d" }).returning_nudge.deliver_now } }
    assert_not_includes logs, @user.email
    assert_not_includes logs, "Delivered mail"
  end

  test "SMTP errors map to codes: auth is systemic, a rejection is permanent, a timeout is retryable; nothing leaks" do
    adapter = Notifications::Email::MailerAdapter.new
    mailer = NotificationMailer
    errors = { "smtp_auth" => Net::SMTPAuthenticationError.new("535 for #{@user.email}"), "smtp_rejected" => Net::SMTPFatalError.new("550 #{@user.email}"),
               "smtp_unavailable" => Net::ReadTimeout.new }
    errors.each do |code, error|
      original = mailer.method(:with)
      mailer.define_singleton_method(:with) { |**| raise error }
      logs = capture_logs { @result = adapter.deliver(user: @user, kind: "ship_approved", values: {}) }
      mailer.define_singleton_method(:with, original)
      assert_equal code, @result.error_code
      assert_equal code == "smtp_auth", @result.systemic ? true : false
      assert_equal code == "smtp_unavailable", @result.retryable ? true : false
      assert_not_includes logs, @user.email
    end
  end

  # --- the unsubscribe token ---

  test "a token is URL-safe, carries no address, and finds the user" do
    token = Notifications::Email::UnsubscribeToken.generate(@user)
    assert_match(/\A[A-Za-z0-9_-]+\z/, token)
    assert_not_includes token, @user.email
    assert_equal @user, Notifications::Email::UnsubscribeToken.user_for(token)
  end

  test "tampered, truncated, empty, oversize and foreign-purpose tokens find nobody" do
    token = Notifications::Email::UnsubscribeToken.generate(@user)
    other = create_email_user("sup2")
    forged_for_other = Notifications::Email::UnsubscribeToken.generate(other).sub(/--.*/, "--#{token.split('--').last}")
    other_purpose = Notifications::Email::UnsubscribeToken.verifier.generate([ @user.id, @user.email_unsubscribe_nonce ], purpose: "something_else")
    plain_verifier_token = Rails.application.message_verifier("email_unsubscribe").generate([ @user.id, @user.email_unsubscribe_nonce ], purpose: "email_unsubscribe")

    [ token[0..-2] + (token[-1] == "a" ? "b" : "a"), token[0, 20], "", nil, "x" * 400, forged_for_other, other_purpose, plain_verifier_token, 12, [ "a" ] ].each do |bad|
      assert_nil Notifications::Email::UnsubscribeToken.user_for(bad), bad.inspect
    end
  end

  test "a token dies when the person is deleted or the nonce is rotated, and never expires otherwise" do
    token = Notifications::Email::UnsubscribeToken.generate(@user)
    travel 5.years do
      assert_equal @user, Notifications::Email::UnsubscribeToken.user_for(token)
    end

    Notifications::Email::Subscription.unsubscribe!(@user)
    assert_equal @user, Notifications::Email::UnsubscribeToken.user_for(token), "unsubscribing does not revoke the link"
    Notifications::Email::Subscription.resubscribe!(@user.reload)
    assert_nil Notifications::Email::UnsubscribeToken.user_for(token), "turning email back on rotates the nonce"
    assert_equal @user, Notifications::Email::UnsubscribeToken.user_for(Notifications::Email::UnsubscribeToken.generate(@user.reload))

    gone = Notifications::Email::UnsubscribeToken.generate(@user)
    User.where(id: @user.id).delete_all
    assert_nil Notifications::Email::UnsubscribeToken.user_for(gone)
  end

  # --- the global switch ---

  test "unsubscribing is idempotent, cancels queued email and leaves Slack rows alone" do
    queued = email_row(@user)
    sent = email_row(@user, status: "sent")
    slack = Notification.create!(user: @user, kind: "ship_approved", channel: "slack_dm", status: "pending", subject_id: 1, scheduled_for: Time.current,
                                 due_at: Time.current, idempotency_key: "slack:sup:1")
    Notifications::Email::Subscription.unsubscribe!(@user)
    first = @user.reload.email_opted_out_at
    assert first
    travel 1.hour do
      Notifications::Email::Subscription.unsubscribe!(@user)
    end
    assert_equal first, @user.reload.email_opted_out_at, "the original time is kept"

    assert queued.reload.cancelled?
    assert_equal "opted_out", queued.last_error_code
    assert sent.reload.sent?
    assert slack.reload.pending?
  end

  test "unsubscribing works even for an address that no longer passes validation" do
    @user.update_columns(email: "legacy address")
    assert Notifications::Email::Subscription.unsubscribe!(@user)
    assert @user.reload.email_opted_out?
  end

  test "resubscribing clears the switch and rotates the nonce, and does nothing for someone who never opted out" do
    nonce = @user.email_unsubscribe_nonce
    assert_not Notifications::Email::Subscription.resubscribe!(@user)
    assert_equal nonce, @user.reload.email_unsubscribe_nonce

    Notifications::Email::Subscription.unsubscribe!(@user)
    assert Notifications::Email::Subscription.resubscribe!(@user.reload)
    assert_not @user.reload.email_opted_out?
    assert_not_equal nonce, @user.email_unsubscribe_nonce
  end

  test "every user starts with a random unsubscribe nonce" do
    other = create_email_user("sup3")
    assert_match(/\A\h{8}-\h{4}-/, @user.email_unsubscribe_nonce)
    assert_not_equal @user.email_unsubscribe_nonce, other.email_unsubscribe_nonce
  end

  # --- preferences per kind and channel ---

  test "per-kind and per-channel switches are independent, and the global switch beats them all" do
    assert Notifications::Preferences.enabled?(@user, "ship_approved", channel: "email")
    Notifications::Preferences.update!(@user, { "ship_approved" => "0" }, "email")
    assert_not Notifications::Preferences.enabled?(@user, "ship_approved", channel: "email")
    assert Notifications::Preferences.enabled?(@user, "ship_approved"), "Slack is a separate switch"
    assert Notifications::Preferences.enabled?(@user, "ship_rejected", channel: "email")

    Notifications::Email::Subscription.unsubscribe!(@user)
    assert_not Notifications::Preferences.enabled?(@user.reload, "ship_rejected", channel: "email")
    assert Notifications::Preferences.enabled?(@user, "ship_rejected")
  end

  test "email carries only its own kinds" do
    %w[daily_reminder link_question ship_reminder ship_mvp bogus].each do |kind|
      assert_not Notifications::Preferences.enabled?(@user, kind, channel: "email"), kind
    end
    assert_equal Notifications::Email::KINDS, Notifications::Preferences.settings(@user, channel: "email").keys
    assert_not Notifications::Preferences.update!(@user, { "daily_reminder" => "0" }, "email")
    assert_equal 0, NotificationPreference.where(user_id: @user.id).count
  end

  # --- deletion ---

  test "the data-deletion API takes the email rows, the email switches and the unsubscribe settings with the person" do
    email_row(@user)
    Notifications::Preferences.update!(@user, { "ship_approved" => "0" }, "email")
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: @user.hca_uid)

    deleted = Privacy::Deleter.new(subject).call(dry_run: false).deleted
    assert_equal 1, deleted["notifications"]
    assert_equal 1, deleted["notification_preferences"]
    assert_equal 0, Notification.where(user_id: @user.id).count
    assert_equal 0, NotificationPreference.where(user_id: @user.id).count
    assert_nil User.find_by(id: @user.id)
  end

  # --- config ---

  test "every emailed kind has a subject, a label and a weekly-cap decision in config" do
    config = Notifications::Email::Config.current
    Notifications::Email::KINDS.each do |kind|
      assert config.subjects.key?(kind), kind
      assert config.label(kind)["title"].present?, kind
    end
    assert_equal [ "returning_nudge" ], config.capped_kinds
    assert_operator config.max_per_week, :>=, 1
  end
end
