require "test_helper"
require_relative "../support/orders_helper"
require_relative "../support/hca_address_helper"
require_relative "../support/privacy_helper"
require_relative "../support/notifications_helper"
require_relative "../support/email_helper"

# One physical order from checkout to deletion, with every feature on, and a scan for the buyer's address, phone number, name,
# tracking number and the staff's free text in every place they must not be: the application logs (at debug, more than production
# writes), the notification outbox, the Slack texts and emails that go out, the CSV export, and (after the person is deleted
# through the data-deletion service) every text and binary column of every table.
class OrderPrivacyEndToEndTest < ActionDispatch::IntegrationTest
  include OrdersTestHelper
  include PrivacyHelper
  include NotificationsHelper
  include EmailHelper

  STREET = "17 Zqprobe Avenue".freeze
  STREET_2 = "99 Zqother Terrace".freeze
  POSTAL = "ZQ99 9ZQ".freeze
  PHONE = "+1 555 010 4477".freeze
  PHONE_DIGITS = "5550104477".freeze
  RECIPIENT = "Zorg Probe-Recipient".freeze
  BUYER = "Zorg Probe-Buyer".freeze
  TRACKING = "ZQTRACK9912345".freeze
  STAFF_NOTE = "ZQ-STAFF-NOTE-TEXT".freeze
  EMAIL = "zq.probe.buyer@example.test".freeze
  NEEDLES = [ STREET, STREET_2, POSTAL, PHONE, PHONE_DIGITS, RECIPIENT, BUYER, TRACKING, STAFF_NOTE, "Zqprobe", "Zqother" ].freeze

  setup do
    # A daytime instant, pinned for the whole flow: the dispatcher holds messages back during quiet hours (22:00 to 07:00 by default),
    # so a run at night with the real clock would send nothing.
    travel_to Time.utc(2026, 11, 16, 12)
    OmniAuth.config.test_mode = true
    Features::NAMES.each { |name| Flipper.enable(name) }
    install_privacy_jwks
    setup_orders_world(coins: 800)
    @buyer.update_columns(display_name: BUYER, email: EMAIL)
    eligible!(@buyer) # the eligibility gate flag is one of the flags that are on
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @original_enabled = ENV["NOTIFICATIONS_ENABLED"]
  end

  teardown do
    teardown_orders_world
    uninstall_privacy_jwks
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_enabled.nil? ? ENV.delete("NOTIFICATIONS_ENABLED") : ENV["NOTIFICATIONS_ENABLED"] = @original_enabled
    travel_back
  end

  def sign_in_as(user)
    claims = user == @buyer ? { "email" => EMAIL, "name" => BUYER, "slack_id" => "U0ORDERBUY", "verification_status" => "verified", "ysws_eligible" => true } : {}
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: claims })
    post "/auth/hack_club"
    follow_redirect!
  end

  def capture_everything
    io = StringIO.new
    loggers = [ Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger ]
    shared = ActiveSupport::Logger.new(io)
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = shared
    shared.level = Logger::DEBUG
    yield
    io.string
  ensure
    Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger = loggers
  end

  def address(id, street)
    hca_address(id, recipient_name: RECIPIENT, line_1: street, postal_code: POSTAL, phone_number: PHONE)
  end

  # Every column of every row of every table, as text (binary columns as hex AND decoded), for a substring scan.
  def whole_database_text
    connection = ActiveRecord::Base.connection
    (connection.tables - %w[schema_migrations ar_internal_metadata]).flat_map do |table|
      connection.select_values("SELECT t::text FROM #{connection.quote_table_name(table)} t")
    end.join("\n")
  end

  test "the address, phone, name, tracking number and staff text stay out of logs, the outbox, messages, emails and the export, and out of the whole database after deletion" do
    ENV["NOTIFICATIONS_ENABLED"] = "true"
    adapter = NotificationsHelper::FakeAdapter.new
    outputs = {}
    csv = nil

    outputs[:log] = capture_everything do
      sign_in_as @buyer
      key = SecureRandom.hex(16)
      AddressOffer.store!(user: @buyer, draft_key: key, result: Hca::Me::Result.new(addresses: [ address("addr_probe_a", STREET) ], skipped: 0))
      post orders_path, params: { prize_key: "tshirt", idempotency_key: key, address_id: "addr_probe_a" }
      flunk "order not placed: #{response.status} #{flash[:alert]} #{response.location}" unless @buyer.orders.exists?
      order = @buyer.orders.order(:id).last
      assert_equal STREET, order.address.line_1, "the order has the address (the owner may see it)"
      get order_path(order)
      assert_includes response.body, STREET

      AddressOffer.store!(user: @buyer, draft_key: "order-#{order.id}", result: Hca::Me::Result.new(addresses: [ address("addr_probe_b", STREET_2) ], skipped: 0))
      get address_order_path(order)
      patch update_address_order_path(order), params: { address_id: "addr_probe_b" }
      assert_equal STREET_2, order.reload.address.line_1
      delete logout_path

      sign_in_as @staff
      get admin_orders_path
      get admin_order_path(order)
      post note_admin_order_path(order), params: { note: STAFF_NOTE }
      patch ship_admin_order_path(order), params: { tracking: { carrier: "ups", number: TRACKING } }
      patch tracking_admin_order_path(order), params: { tracking: { carrier: "ups", number: TRACKING } }
      post reveal_address_admin_order_path(order)
      assert_includes response.body, STREET_2, "staff get the address on the reveal response only"
      get admin_order_path(order)
      assert_not_includes response.body, STREET_2
      post export_admin_orders_path, params: { include_contact: "1" }
      csv = response.body
      get admin_audit_path
      get admin_user_path(@buyer)
      patch fulfil_admin_order_path(order)
      delete logout_path

      with_env("APP_URL" => "https://battletown.example") { Notifications::Dispatcher.run(now: Time.current + 1.minute, adapter: adapter, config: Notifications::Config.current) }
    end

    assert_not_empty adapter.calls, "the shipped and fulfilled messages went out"
    outputs[:slack_texts] = adapter.calls.map { |call| call[:text] }.join("\n")
    outputs[:emails] = ActionMailer::Base.deliveries.map { |mail| [ mail.subject, mail.to, mail.body.to_s, mail.parts.map { |part| part.body.to_s } ].flatten.join("\n") }.join("\n")
    outputs[:outbox] = Notification.all.map { |row| row.attributes.to_json }.join("\n")
    outputs[:csv] = csv
    outputs[:audit] = AdminAuditEvent.all.map { |event| event.attributes.to_json }.join("\n")
    outputs[:order_events] = OrderEvent.where.not(action: "note_added").map { |event| event.attributes.to_json }.join("\n")

    assert_includes csv, "T-shirt", "the export has the order"
    assert_includes csv, BUYER, "contact columns were asked for, so the buyer's display name is there on purpose"
    outputs[:csv] = csv.gsub(BUYER, "").gsub(/U0ORDERBUY/, "") # the only personal columns the staff opted into

    outputs.each do |where, text|
      assert_operator text.length, :>, 20, "#{where} should have content" unless where == :emails
      NEEDLES.each do |needle|
        assert_not_includes text.to_s, needle, "#{needle.inspect} must not appear in #{where}"
      end
    end
    assert_no_match(/xox[bpa]-/, outputs[:log])

    assert_includes whole_database_text, BUYER, "control: the scan does see plain text (the buyer's name is in users until they are deleted)"
    assert_not_includes whole_database_text, STREET_2, "the address columns are ciphertext at rest"

    # After the retention period the purge deletes the address; the buyer is then deleted through the data-deletion service.
    travel_to Time.current + 32.days
    assert_equal 1, Orders::PurgeAddresses.all
    claims = privacy_claims(subject: privacy_subject(emails: [ EMAIL ], slack_id: "U0ORDERBUY", identity_id: @buyer.hca_uid))
    privacy_call("delete", privacy_token(claims))
    assert_response :ok
    assert_not User.exists?(@buyer.id)

    database = whole_database_text
    NEEDLES.each { |needle| assert_not_includes database, needle, "#{needle.inspect} is still in the database after the person was deleted" }
    assert_not_includes database, EMAIL
    assert_equal 0, Order.where(user_id: @buyer.id).count
  end
end
