require "test_helper"
require_relative "../support/shop_helper"

# AddressOffer: the short-lived, encrypted list of a person's Hack Club Auth addresses at checkout.
class AddressOfferTest < ActiveSupport::TestCase
  include ShopTestHelper

  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
  end

  def raw(offer) = ActiveRecord::Base.connection.select_one("SELECT * FROM address_offers WHERE id = #{offer.id}")

  def store(user = @user, draft = "draft-a", addresses = [ hca_address("addr_one"), hca_address("addr_two") ])
    AddressOffer.store!(user: user, draft_key: draft, result: Hca::Me::Result.new(addresses: addresses, skipped: 1))
  end

  test "the payload is ciphertext at rest and reads back" do
    offer = store
    assert_not_includes raw(offer)["payload"], "Example Street"
    assert_not_includes raw(offer)["payload"], "addr_one"
    assert_equal %w[addr_one addr_two], AddressOffer.find(offer.id).addresses.map(&:id)
    assert_equal 1, AddressOffer.find(offer.id).skipped
    assert_not_includes offer.inspect, "Example Street"
  end

  test "an offer expires after the configured minutes" do
    offer = store
    assert_in_delta Orders::Config.current.address_offer_minutes.minutes.from_now.to_f, offer.expires_at.to_f, 5
    assert_equal 15, Orders::Config.current.address_offer_minutes
    assert_not_nil AddressOffer.live_for(@user, "draft-a")
    travel 14.minutes do
      assert_not_nil AddressOffer.live_for(@user, "draft-a")
    end
    travel 16.minutes do
      assert_nil AddressOffer.live_for(@user, "draft-a")
      assert AddressOffer.expired_for?(@user, "draft-a")
    end
  end

  test "one offer per person: a new lookup replaces every older one of theirs, and never touches anybody else's" do
    store(@user, "draft-a")
    store(@other, "draft-a", [ hca_address("addr_theirs") ])
    store(@user, "draft-b")
    assert_nil AddressOffer.live_for(@user, "draft-a")
    assert_not_nil AddressOffer.live_for(@user, "draft-b")
    assert_equal %w[addr_theirs], AddressOffer.live_for(@other, "draft-a").addresses.map(&:id)
    assert_equal 2, AddressOffer.count
  end

  test "the same checkout twice keeps one row (a unique key backs it)" do
    store
    store
    assert_equal 1, AddressOffer.where(user: @user, draft_key: "draft-a").count
    assert_raises(ActiveRecord::RecordNotUnique) { AddressOffer.new(user: @user, draft_key: "draft-a", payload: "{}", expires_at: 1.minute.from_now).save!(validate: false) }
  end

  test "using an offer marks it used and empties it" do
    offer = store
    offer.use!
    assert_not_nil offer.reload.used_at
    assert_empty offer.addresses
    assert_not_includes ActiveRecord::Base.connection.select_value("SELECT payload FROM address_offers WHERE id = #{offer.id}"), "addr_one"
    assert_nil AddressOffer.live_for(@user, "draft-a")
  end

  test "an id is only found in the offer's own list, as a plain string" do
    offer = store
    assert_equal "addr_one", offer.find_address("addr_one").id
    [ nil, "", "addr_none", :addr_one, [ "addr_one" ], { id: "addr_one" } ].each { |bad| assert_nil offer.find_address(bad), bad.inspect }
  end

  test "a draft key that is not a plain key finds nothing" do
    store
    [ nil, "", "a b", "../x", [ "draft-a" ], "x" * 101 ].each { |bad| assert_nil AddressOffer.live_for(@user, bad), bad.inspect }
  end

  test "stale offers are swept when a new one is stored, and by the purge" do
    old = store(@other, "old")
    travel 20.minutes do
      store
      assert_not AddressOffer.exists?(old.id)
    end
    store(@other, "x")
    travel 20.minutes do
      assert_equal 1, Orders::PurgeAddresses.purge_offers, "only the expired one goes"
      assert_equal 1, AddressOffer.count
    end
  end

  test "deleting the person deletes their offers" do
    store
    assert_difference -> { AddressOffer.count }, -1 do
      User.where(id: @user.id).delete_all
    end
  end
end
