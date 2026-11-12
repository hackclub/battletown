require "test_helper"
require_relative "../support/email_helper"

class NotificationMailerTest < ActionMailer::TestCase
  include EmailHelper

  APP = "https://battletown.example.test".freeze

  setup do
    @user = create_email_user("mail1")
    @values = {
      "ship_approved" => { project: "Space Farm", hours: "3", coins: 42, locked: true, verify_url: "https://example.test/verify", link: "#{APP}/ships/1" },
      "ship_rejected" => { project: "Space Farm", reason: "The demo link does not open.", link: "#{APP}/projects/1/ships/new?from=1" },
      "returning_nudge" => { boost_days: 3, link: "#{APP}/dashboard" },
      "order_shipped" => { item: "Sticker pack", link: "#{APP}/shop/orders/1" }
    }
  end

  def build(kind, values: @values.fetch(kind))
    with_env("APP_URL" => APP, "MAIL_FROM" => "Battletown <noreply@example.test>") do
      # Mailers are lazy: .message runs the action (and renders) here, while the environment is set.
      NotificationMailer.with(user: @user, values: values).public_send(kind).tap(&:message)
    end
  end

  def mail_for(kind) = with_feature(:email) { build(kind).message }

  test "there is one mailer action and one template pair per emailed kind" do
    assert_equal %w[order_shipped returning_nudge ship_approved ship_rejected], Notifications::Email::KINDS.sort
    Notifications::Email::KINDS.each do |kind|
      assert_includes NotificationMailer.action_methods, kind
      assert Rails.root.join("app/views/notification_mailer/#{kind}.text.erb").exist?
      assert Rails.root.join("app/views/notification_mailer/#{kind}.html.erb").exist?
    end
  end

  test "every kind renders multipart text and HTML with its link, the reason and the program note" do
    Notifications::Email::KINDS.each do |kind|
      mail = mail_for(kind)
      assert mail.multipart?, kind
      text = mail.text_part.body.to_s
      html = mail.html_part.body.to_s
      assert_includes text, @values.fetch(kind)[:link], kind
      assert_includes html, %(href="#{@values.fetch(kind)[:link]}"), kind
      [ text, html ].each do |body|
        assert_includes body, "You get this because you have a Battletown account", kind
        assert_includes body, "Hack Club program", kind
        assert_includes body, "#{APP}/settings/notifications", kind
        assert_no_match(/hackclub|HackClub|hack club/, body, kind)
      end
    end
  end

  test "subjects come from config and carry only the shortened project name" do
    assert_equal "Your Space Farm ship was approved", mail_for("ship_approved").subject
    assert_equal "Your Space Farm ship needs one more touch", mail_for("ship_rejected").subject
    assert_equal "The boss is still standing.", mail_for("returning_nudge").subject
    assert_equal "Your Sticker pack order has shipped", mail_for("order_shipped").subject
  end

  test "a project name with a line break can never break the subject header" do
    mail = with_feature(:email) { build("ship_approved", values: @values["ship_approved"].merge(project: "Evil\r\nBcc: x@example.test")).message }
    assert_no_match(/[\r\n]/, mail.subject)
    assert_nil mail.bcc
  end

  test "the from address is MAIL_FROM, and the recipient is the user's address" do
    mail = mail_for("ship_approved")
    assert_equal [ "noreply@example.test" ], mail.from
    assert_equal [ @user.email ], mail.to
  end

  test "RFC 8058 one-click headers point at the signed unsubscribe address and the footer links to it" do
    mail = mail_for("ship_rejected")
    token = Notifications::Email::UnsubscribeToken.generate(@user)
    url = "#{APP}/email/unsubscribe/#{token}"
    assert_equal "<#{url}>", mail["List-Unsubscribe"].to_s
    assert_equal "List-Unsubscribe=One-Click", mail["List-Unsubscribe-Post"].to_s
    assert_includes mail.text_part.body.to_s, url
    assert_includes mail.html_part.body.to_s, %(href="#{url}")
    assert_equal @user, Notifications::Email::UnsubscribeToken.user_for(token)
  end

  test "no remote images, tracking pixels, scripts or tracked links" do
    Notifications::Email::KINDS.each do |kind|
      html = mail_for(kind).html_part.body.to_s
      assert_no_match(/<img|<script|<link|<iframe|url\(|@import/i, html, kind)
      hrefs = html.scan(/href="([^"]+)"/).flatten
      assert_not_empty hrefs
      hrefs.each { |href| assert href.start_with?(APP, "https://example.test/verify"), "#{kind}: #{href}" }
      assert_no_match(/utm_|track|pixel|redirect/i, html, kind)
    end
  end

  test "user-supplied text is HTML-escaped" do
    values = @values["ship_rejected"].merge(project: "<b>Bold</b>", reason: "<script>alert(1)</script>")
    html = with_feature(:email) { build("ship_rejected", values: values).message.html_part.body.to_s }
    assert_no_match(/<script>alert/, html)
    assert_includes html, "&lt;script&gt;"
    assert_includes html, "&lt;b&gt;Bold&lt;/b&gt;"
  end

  test "the approved email mentions the identity step only while coins are locked" do
    assert_includes mail_for("ship_approved").text_part.body.to_s, "verify your identity with Hack Club"
    unlocked = with_feature(:email) { build("ship_approved", values: @values["ship_approved"].merge(locked: false)).message }
    assert_no_match(/verify your identity/, unlocked.text_part.body.to_s)
  end

  test "with the email flag off no message is built or delivered, whoever asks" do
    without_feature(:email) do
      clear_deliveries
      Notifications::Email::KINDS.each do |kind|
        build(kind).deliver_now
      end
      assert_empty deliveries
    end
  end

  test "delivering with the flag on puts exactly one message in the test mailbox" do
    with_feature(:email) do
      clear_deliveries
      build("ship_approved").deliver_now
      assert_equal 1, deliveries.size
    end
  end
end
