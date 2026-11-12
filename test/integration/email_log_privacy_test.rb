require "test_helper"
require_relative "../support/email_helper"

# The whole email path with every logger captured: no address, subject or body ever reaches a log, and no notification
# row holds one.
class EmailLogPrivacyTest < ActionDispatch::IntegrationTest
  include EmailHelper

  def capture_everything
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = Logger::DEBUG
    # Action Mailer's own logger is left as configured (silenced): that is part of what is proven here.
    originals = [ Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger ]
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
    yield
    io.string
  ensure
    Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger = originals
  end

  test "queueing, dispatching, delivering and unsubscribing log no address, subject or body" do
    user = create_email_user("priv1", email: "private.teen@example.test", display_name: "Private Teen")
    token = nil
    logs = capture_everything do
      with_feature(:email) do
        decided_ship(user, :approved, name: "Secret Project Name")
        Notification.where(user_id: user.id, channel: "email").update_all(due_at: Time.utc(2026, 11, 11, 11), scheduled_for: Time.utc(2026, 11, 11, 11))
        with_env("NOTIFICATIONS_ENABLED" => "true") do
          Notifications::Email::Dispatcher.run(now: Time.utc(2026, 11, 11, 12), adapter: Notifications::Email::MailerAdapter.new)
        end
        token = Notifications::Email::UnsubscribeToken.generate(user)
        get "/email/unsubscribe/#{token}"
        post "/email/unsubscribe/#{token}"
      end
    end

    assert_equal 1, deliveries.size, "the mail really was built and went to the test mailbox"
    assert_includes logs, "notifications.email queued kind=ship_approved"
    [ "private.teen@example.test", "Private Teen", "Secret Project Name", "was approved", "Good news", "Your Secret Project" ].each do |secret|
      assert_not_includes logs, secret
    end
    assert_not_includes logs, "Delivered mail"
  end

  test "no notification or preference row can hold an address or text" do
    columns = (Notification.column_names + NotificationPreference.column_names).uniq
    assert_empty columns.grep(/email|address|body|text|subject_line|message|to\b/), "unexpected columns: #{columns.inspect}"
  end

  test "the stored email row has the address nowhere in any column" do
    user = create_email_user("priv2", email: "another.teen@example.test")
    with_feature(:email) { decided_ship(user, :rejected) }
    row = Notification.find_by!(user_id: user.id, channel: "email")
    assert_not_includes row.attributes.values.join(" "), "another.teen"
  end
end
