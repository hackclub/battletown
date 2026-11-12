require "test_helper"
require_relative "../support/privacy_helper"
require_relative "../support/orders_helper"
require_relative "../support/hackatime_helper"

# Shipping addresses and the data-deletion service (yeet): the dry run and the real run count the new tables, the person's addresses
# and offers are gone afterwards, the export names counts only, and nothing leaks into the response or the log.
class AddressPrivacyTest < ActionDispatch::IntegrationTest
  include PrivacyHelper
  include OrdersTestHelper
  include HackatimeHelper # capture_logs

  setup do
    install_privacy_jwks
    setup_orders_world(coins: 500)
    @buyer.update_columns(email: "yeet.address@example.test")
    @order = order_for(address: true)
    @second = order_for(prize: "keychain", address: true)
    offer_addresses!(@buyer, "draft-yeet")
    give_coins(@other, 200)
    bystander_order = order_for(@other, address: true)
    @bystander_address = bystander_order.address
    offer_addresses!(@other, "draft-other")
  end

  teardown do
    teardown_orders_world
    uninstall_privacy_jwks
  end

  def call_yeet(action, dry_run: false)
    claims = privacy_claims(action: action, dry_run: dry_run, subject: privacy_subject(emails: [ "yeet.address@example.test" ], slack_id: nil, identity_id: @buyer.hca_uid))
    privacy_call(action, privacy_token(claims))
    assert_response :ok
    response.parsed_body
  end

  test "the dry run counts order_addresses and address_offers, the real run matches and deletes them, and the bystander is untouched" do
    dry = call_yeet("delete", dry_run: true)
    assert_equal 2, dry.dig("deleted", "order_addresses")
    assert_equal 1, dry.dig("deleted", "address_offers")
    assert_equal 2, OrderAddress.where(user_id: @buyer.id).count, "a dry run deletes nothing"
    assert_equal 1, AddressOffer.where(user_id: @buyer.id).count

    real = call_yeet("delete")
    assert_equal dry["deleted"], real["deleted"]
    assert_equal 0, OrderAddress.where(user_id: @buyer.id).count
    assert_equal 0, OrderAddress.where(order_id: [ @order.id, @second.id ]).count
    assert_equal 0, AddressOffer.where(user_id: @buyer.id).count
    assert OrderAddress.exists?(@bystander_address.id)
    assert_equal 1, AddressOffer.where(user_id: @other.id).count
  end

  test "the response holds counts only: no address text, no phone, no ids of addresses" do
    page = nil
    logs = capture_logs do
      call_yeet("delete", dry_run: true)
      page = response.body
      call_yeet("delete")
      page += response.body
    end
    [ "Example Street", "Exampleville", "+15555550123", "addr_", "Pat Example" ].each do |secret|
      assert_not_includes page, secret
      assert_not_includes logs, secret
    end
  end

  test "the export names the tables and counts and never the address" do
    export = call_yeet("export")
    assert_not_includes export.to_json, "Example Street"
    assert_not_includes export.to_json, "+15555550123"
    assert_equal 2, export.dig("deleted", "order_addresses"), "the export reports counts per table, including the new ones"
    assert_equal 1, export.dig("deleted", "address_offers")
    assert_equal 2, OrderAddress.where(user_id: @buyer.id).count, "an export deletes nothing"
  end
end
