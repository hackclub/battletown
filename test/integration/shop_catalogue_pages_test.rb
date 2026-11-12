require "test_helper"
require_relative "../support/shop_helper"
require_relative "../support/ship_images_helper"

# What people see when staff change the catalogue (/admin/shop): archived items disappear from the shop, the landing page and
# the onboarding picker, but stay valid for stored picks and past orders; and the catalogue costs the pages one query.
class ShopCataloguePagesTest < ActionDispatch::IntegrationTest
  include ShopTestHelper
  include ShipImagesHelper

  setup do
    OmniAuth.config.test_mode = true
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @user = users(:onboarded)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def archive(key) = ShopItem.find_by!(key: key).update!(active: false)

  def catalogue_queries
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].match?(/FROM "shop_items"/) && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  # --- archived items are out of sight ---

  test "an archived item is gone from the shop grid and its confirmation page, with a friendly note" do
    give_coins(@user, 200)
    verified!(@user)
    sign_in_as @user
    get shop_path
    assert_select ".shop-item h3", text: "Keychain"

    archive("keychain")
    get shop_path
    assert_response :success
    assert_select ".shop-item h3", text: "Keychain", count: 0
    assert_select ".shop-item", Prize.paid.size

    get shop_item_path("keychain")
    assert_redirected_to shop_path
    follow_redirect!
    assert_select ".flash, .alert", /That item isn't in the shop any more/
  end

  test "an item that never existed, and the free sticker, are still a plain 404 on the confirmation page" do
    verified!(@user)
    sign_in_as @user
    get shop_item_path("no_such_item")
    assert_response :not_found
    get shop_item_path("signup_sticker")
    assert_response :not_found
  end

  test "an archived item is gone from the landing page for signed-out visitors" do
    get "/"
    assert_select ".prize h3", text: "Poster"
    archive("poster")
    get "/"
    assert_response :success
    assert_select ".prize h3", text: "Poster", count: 0
    assert_select ".prize", Prize.paid.size
  end

  test "an archived item is gone from the onboarding picker but a stored pick of it still works" do
    archive("poster")
    teen = users(:new_user)
    sign_in_as teen
    get onboarding_step_path("prize")
    assert_response :success
    assert_select "input[name='user[prize_key]'][value='poster']", 0
    assert_select "label.choice", Prize.paid.size

    patch onboarding_step_path("prize"), params: { user: { prize_key: "poster" } }
    assert_response :unprocessable_content
    assert_nil teen.reload.prize_key, "a new pick must be an item that is still on offer"

    patch onboarding_step_path("prize"), params: { user: { prize_key: "tshirt" } }
    assert_equal "tshirt", teen.reload.prize_key
  end

  test "a person who already picked an item that is now archived keeps a valid user, the dashboard and the celebration page" do
    @user.update_columns(prize_key: "keychain")
    archive("keychain")
    assert_predicate @user.reload, :valid?
    assert_equal "Keychain", @user.prize.name
    assert_not_predicate @user.prize, :active?
    sign_in_as @user
    get dashboard_path
    assert_response :success
    assert_equal "keychain", @user.reload.prize_key
  end

  test "a prize that was archived and then restored comes back everywhere" do
    archive("poster")
    ShopItem.find_by!(key: "poster").update!(active: true)
    get "/"
    assert_select ".prize h3", text: "Poster"
  end

  # --- orders keep working ---

  test "buying an archived item is refused with a friendly error and charges nothing" do
    give_coins(@user, 200)
    verified!(@user)
    archive("keychain")
    error = assert_raises(Shop::ItemUnavailable) { buy(@user, "keychain") }
    assert_match(/isn't in the shop any more/, error.message)
    assert_equal 0, Order.count
    assert_equal 200, Coins::Balance.total(@user)

    sign_in_as @user
    post orders_path, params: { prize_key: "keychain", idempotency_key: "abc123" }
    assert_redirected_to shop_path
    follow_redirect!
    assert_select ".flash, .alert", /isn't in the shop any more/
    assert_equal 0, Order.count
  end

  test "an order made before the item was archived can still be cancelled, refunded and fulfilled" do
    give_coins(@user, 200)
    verified!(@user)
    first = buy(@user, "keychain")
    second = buy(@user, "keychain")
    archive("keychain")

    ENV["ADMIN_HCA_UIDS"] = users(:new_user).hca_uid
    admin = users(:new_user)
    Shop::Cancel.call(order: first, by: @user)
    assert_equal "cancelled", first.reload.status
    assert_equal 170, Coins::Balance.total(@user)
    Shop::Fulfill.call(order: second, by: admin)
    assert_equal "fulfilled", second.reload.status
    assert_equal "Keychain", second.display_name
    assert_equal "keychain", second.prize.key
    assert_predicate second, :valid?
  ensure
    ENV.delete("ADMIN_HCA_UIDS")
  end

  test "the orders page still lists an archived item" do
    give_coins(@user, 200)
    verified!(@user)
    buy(@user, "keychain")
    archive("keychain")
    sign_in_as @user
    get orders_path
    assert_response :success
    assert_select ".shop-order", /Keychain/
  end

  test "a price change leaves past orders alone" do
    give_coins(@user, 200)
    verified!(@user)
    order = buy(@user, "keychain")
    ShopItem.find_by!(key: "keychain").update!(coins: 99, name: "Fancy keychain")
    order.reload
    assert_equal [ 30, "Keychain" ], [ order.coins, order.prize_name ]
    assert_equal "Fancy keychain", order.prize.name
    assert_equal "Keychain", order.display_name
    Shop::Cancel.call(order: order, by: @user)
    assert_equal 200, Coins::Balance.total(@user)
  end

  # --- the free sticker ---

  test "the claim flow uses the free signup item as staff edited it" do
    ShopItem.find_by!(key: "signup_sticker").update!(name: "Welcome pin", description: "A pin, on us.", emoji: "📌")
    sign_in_as @user
    get shop_path
    assert_select ".shop-sticker", /A pin, on us/
    post shop_sticker_path
    order = Order.find_by!(user: @user, kind: "signup_sticker")
    assert_equal [ "signup_sticker", "Welcome pin", 0 ], [ order.prize_key, order.prize_name, order.coins ]
  end

  test "with the free sticker archived the shop hides the claim box and a claim is refused" do
    archive("signup_sticker")
    assert_nil Prize.free_signup
    assert_includes Prize.keys, "signup_sticker"
    sign_in_as @user
    get shop_path
    assert_response :success
    assert_select ".shop-sticker", 0

    post shop_sticker_path
    assert_redirected_to shop_path
    assert_equal 0, Order.count
    assert_raises(Shop::ItemUnavailable) { Shop::ClaimSticker.call(user: @user) }
  end

  test "someone who claimed the sticker keeps the order when it is archived" do
    sign_in_as @user
    post shop_sticker_path
    archive("signup_sticker")
    get orders_path
    assert_response :success
    assert_select ".shop-order", /sticker/i
    assert_equal 1, Order.where(user: @user, kind: "signup_sticker").count
  end

  test "there is only ever one free signup item on offer" do
    assert_equal 1, Prize.all.count(&:free_signup?)
    assert_equal 1, ShopItem.where(kind: "free_signup").count
  end

  # --- pictures on the public pages ---

  test "an item's picture appears on the shop, the landing page and the onboarding picker, from this site only" do
    processed = ShipImages::Processor.call(upload_file(png_bytes(80, 40)), config: ShopItems::Config.current)
    ShopItem.find_by!(key: "poster").tap { |item| item.attach_image(processed) }.save!
    path = ShopItem.without_content.find_by!(key: "poster").image_path

    get "/"
    assert_equal [ path ], css_select(".prize img").map { |img| img["src"] }.grep(%r{/shop/items/})
    sign_in_as users(:new_user)
    get onboarding_step_path("prize")
    assert_equal [ path ], css_select(".choice__image").map { |img| img["src"] }
    delete logout_path

    verified!(@user)
    sign_in_as @user
    get shop_path
    assert_equal [ path ], css_select(".shop-item__image").map { |img| img["src"] }
    assert_select "img[src^='http']", 0
  end

  # --- no extra queries ---

  test "the catalogue costs the landing page one query however many prizes there are" do
    assert_equal 1, catalogue_queries { get "/" }
    ShopItem.insert_all!(10.times.map { |i| { key: "extra_#{i}", name: "Extra #{i}", description: "", coins: 5 + i, tier: "shop", kind: "regular", position: 100 + i, active: true, created_at: Time.current, updated_at: Time.current } })
    Prize.reload!
    assert_equal 1, catalogue_queries { get "/" }
    assert_select ".prize", Prize.paid.size
  end

  test "the catalogue costs the shop page one query" do
    give_coins(@user, 100)
    verified!(@user)
    sign_in_as @user
    assert_equal 1, catalogue_queries { get shop_path }
  end

  test "the catalogue costs the dashboard at most one query" do
    @user.update_columns(prize_key: "tshirt")
    sign_in_as @user
    assert_operator catalogue_queries { get dashboard_path }, :<=, 1
  end

  test "the catalogue costs the onboarding prize step at most one query" do
    sign_in_as users(:new_user)
    assert_operator catalogue_queries { get onboarding_step_path("prize") }, :<=, 1
  end

  test "a request never loads picture bytes into the catalogue" do
    processed = ShipImages::Processor.call(upload_file(png_bytes(80, 40)), config: ShopItems::Config.current)
    ShopItem.find_by!(key: "poster").tap { |item| item.attach_image(processed) }.save!
    statements = []
    collector = ->(*, payload) { statements << payload[:sql] if payload[:sql].include?(%(FROM "shop_items")) }
    ActiveSupport::Notifications.subscribed(collector, "sql.active_record") { get "/" }
    assert statements.any?
    assert(statements.none? { |sql| sql.include?("image_content") }, statements.inspect)
  end

  test "a catalogue change shows on the very next request" do
    get "/"
    assert_select ".prize h3", text: "Poster"
    ShopItem.find_by!(key: "poster").update!(name: "Big poster")
    get "/"
    assert_select ".prize h3", text: "Big poster"
    assert_select ".prize h3", text: "Poster", count: 0
  end
end
