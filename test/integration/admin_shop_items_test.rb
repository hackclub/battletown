require "test_helper"
require_relative "../support/ship_images_helper"
require_relative "../support/shop_helper"

class AdminShopItemsTest < ActionDispatch::IntegrationTest
  include ShipImagesHelper
  include ShopTestHelper

  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @admin = users(:onboarded)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def admin!
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @admin
  end

  def item_params(**overrides)
    { shop_item: { key: "pixel_pin", name: "Pixel pin", description: "A tiny pin.", emoji: "📌", coins: "25", tier: "shop", position: "", active: "1" }.merge(overrides) }
  end

  def create_pin(**overrides)
    post "/admin/shop", params: item_params(**overrides)
    ShopItem.find_by(key: overrides.fetch(:key, "pixel_pin"))
  end

  test "numbers too big for the database are a form error or a stale-form message, never a 500" do
    admin!
    post "/admin/shop", params: item_params(position: "99999999999")
    assert_response :unprocessable_content
    post "/admin/shop", params: item_params(coins: "99999999999999999999")
    assert_response :unprocessable_content
    patch "/admin/shop/tshirt", params: { shop_item: { coins: "60", lock_version: "99999999999999999999" } }
    assert_response :see_other
    assert_match(/Someone else changed/, flash[:alert].to_s)
    patch "/admin/shop/tshirt", params: { shop_item: { position: "99999999999" } }
    assert_response :unprocessable_content
    assert_not_equal 60, ShopItem.find_by!(key: "tshirt").coins
  end

  # Found by the volume run: the list read an old three-status badge table and answered 500 as soon as one order was on hold,
  # shipped or refunded.
  test "the list and the edit page show counts for orders in every one of the six statuses" do
    buyer = users(:new_user)
    give_coins(buyer, 1000)
    Order::STATUSES.each_with_index do |status, index|
      stamp = { "fulfilled" => :fulfilled_at, "cancelled" => :cancelled_at, "shipped" => :shipped_at, "refunded" => :refunded_at }[status]
      attrs = { user: buyer, prize_key: "keychain", prize_name: "Keychain", coins: 30, kind: "purchase", idempotency_key: "six-#{index}", status: status }
      attrs[stamp] = Time.current if stamp
      Order.create!(attrs)
    end
    admin!
    get "/admin/shop"
    assert_response :success
    Order::STATUSES.each { |status| assert_select ".admin-shop-counts li", text: /1 #{status.tr('_', ' ')}/ }
    get "/admin/shop/keychain/edit"
    assert_response :success
  end

  # --- who can reach it ---

  test "signed-out visitors and non-admins get a 404 on every shop admin route and nothing changes" do
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    before = ShopItem.pluck(:key, :coins, :active, :position).sort
    checks = lambda do
      get "/admin/shop"
      assert_response :not_found
      get "/admin/shop/new"
      assert_response :not_found
      get "/admin/shop/tshirt/edit"
      assert_response :not_found
      post "/admin/shop", params: item_params
      assert_response :not_found
      patch "/admin/shop/tshirt", params: { shop_item: { coins: "1" } }
      assert_response :not_found
      patch "/admin/shop/tshirt/archive"
      assert_response :not_found
      patch "/admin/shop/tshirt/restore"
      assert_response :not_found
      patch "/admin/shop/tshirt/move", params: { direction: "up" }
      assert_response :not_found
    end
    checks.call
    sign_in_as @admin
    checks.call
    assert_equal before, ShopItem.pluck(:key, :coins, :active, :position).sort
  end

  # Table-driven from the router, so a route added later is covered without anyone listing it here.
  def shop_admin_routes
    Rails.application.routes.routes.filter_map do |route|
      next unless route.defaults[:controller] == "admin/shop_items"

      [ route.verb.to_s.gsub(/[^A-Z]/, ""), route.path.spec.to_s.sub("(.:format)", "").gsub(":key", "tshirt") ]
    end
  end

  test "every shop admin route in the router is a 404 for visitors and non-admins, and rejects a missing CSRF token for admins" do
    routes = shop_admin_routes
    assert_operator routes.size, :>=, 8
    assert_equal %w[GET PATCH POST], routes.map(&:first).uniq.sort, "no route may delete"

    original = ActionController::Base.allow_forgery_protection
    check = lambda do |expected, message|
      ActionController::Base.allow_forgery_protection = true
      routes.each do |verb, path|
        next if expected == :unprocessable_content && verb == "GET"

        process(verb.downcase.to_sym, path)
        assert_response expected, "#{verb} #{path} #{message}"
      end
      ActionController::Base.allow_forgery_protection = original
    end

    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    check.call(:not_found, "must be a 404 for a visitor")
    sign_in_as @admin
    check.call(:not_found, "must be a 404 for a non-admin")
    delete logout_path
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @admin
    check.call(:unprocessable_content, "must need a CSRF token")
    assert ShopItem.exists?(key: "tshirt", active: true)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "a non-admin's 404 is the same page an unknown path gets" do
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    sign_in_as @admin
    get "/definitely-not-a-page"
    missing = response.body
    get "/admin/shop"
    assert_equal missing, response.body
  end

  test "there is no way to delete an item" do
    admin!
    delete "/admin/shop/tshirt"
    assert_response :not_found
    assert_equal 0, Rails.application.routes.routes.count { |route| route.verb.to_s.include?("DELETE") && route.path.spec.to_s.start_with?("/admin/shop") }
    assert ShopItem.exists?(key: "tshirt")
  end

  test "an admin sees the list in position order with aggregate numbers and no-store" do
    admin!
    get "/admin/shop"
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only"
    assert_select "h1", "Shop items"
    keys = css_select("tbody tr").map { |row| row["id"] }
    assert_equal ShopItem.active.in_order.map { |item| "item-#{item.key}" }, keys
    assert_select "tr#item-tshirt td", /50/
    assert_select "tr#item-tshirt", /5 hours/
    assert_no_match(/\$|dollar|USD/i, response.body)
    assert_select "nav[aria-label='Which items'] a[aria-current=page]", /In the shop \(10\)/
  end

  test "the list shows how many people picked an item and its orders by status" do
    buyer = users(:new_user)
    buyer.update_columns(onboarded_at: Time.current, onboarding_step: 4, prize_key: "keychain")
    users(:onboarded).update_columns(prize_key: "keychain")
    verified!(buyer)
    give_coins(buyer, 200)
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    first = buy(buyer, "keychain")
    buy(buyer, "keychain")
    Shop::Fulfill.call(order: first, by: @admin)
    buy(buyer, "tshirt")
    admin!

    get "/admin/shop"
    row = css_select("tr#item-keychain").first
    assert_includes row.text, "1 requested"
    assert_includes row.text, "1 fulfilled"
    assert_equal "2", css_select("tr#item-keychain td.num").last.text.strip
    assert_not_includes row.text, "cancelled"
    assert_includes css_select("tr#item-tshirt").first.text, "1 requested"
    assert_includes css_select("tr#item-poster").first.text, "None yet"
    assert_no_match(/#{Regexp.escape(buyer.display_name.to_s)}/, response.body) if buyer.display_name.present?
  end

  test "the admin dashboard links to the shop items" do
    admin!
    get "/admin"
    assert_select "a[href='/admin/shop']", "Shop items"
  end

  # --- adding ---

  test "an admin adds an item: it joins the end of the shop and is audited" do
    admin!
    get "/admin/shop/new"
    assert_response :success
    assert_select "form[enctype='multipart/form-data']"
    assert_select "input[name='shop_item[key]']"
    assert_select "input[name='shop_item[coins]']"
    assert_select "[name*=usd], [name*=dollar], [name*=price]", 0
    assert_select "#item-coins-hint", /about 1 hour of approved coding/

    top = ShopItem.maximum(:position)
    assert_difference -> { ShopItem.count }, 1 do
      post "/admin/shop", params: item_params
    end
    assert_redirected_to "/admin/shop"
    item = ShopItem.find_by!(key: "pixel_pin")
    assert_equal [ "Pixel pin", 25, "shop", "regular", true, top + 1 ], [ item.name, item.coins, item.tier, item.kind, item.active, item.position ]
    assert_not_predicate item, :image?

    follow_redirect!
    assert_select "tr#item-pixel_pin", /Pixel pin/
    assert_select ".flash, .alert", /Added Pixel pin/
    assert_equal "Pixel pin", Prize.find("pixel_pin").name
    assert_includes Prize.paid.map(&:key), "pixel_pin"
  end

  test "the form never asks for a dollar amount and only for coins" do
    admin!
    get "/admin/shop/new"
    form = css_select("form.admin-form").first.to_s
    assert_no_match(/dollar|usd|\$|cost to us|shipping (cost|fee|price)|postage|budget/i, form)
    assert_match(/Price \(coins\)/, form)
  end

  test "bad input is refused with friendly errors and keeps what was typed" do
    admin!
    assert_no_difference -> { ShopItem.count } do
      post "/admin/shop", params: item_params(key: "Bad Key", name: "", coins: "0", description: "d" * 201)
    end
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", /Key can only use lowercase letters/
    assert_select ".admin-form__errors li", /Name can't be blank/
    assert_select ".admin-form__errors li", /Coins must be more than 0/
    assert_select ".admin-form__errors li", /Description is too long/
    assert_select "input[name='shop_item[key]'][value='Bad Key']"
  end

  test "a key that is already used is refused" do
    admin!
    post "/admin/shop", params: item_params(key: "tshirt")
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", /Key is already used/
  end

  test "an item can be added archived, and stays out of the shop until restored" do
    admin!
    post "/admin/shop", params: item_params(active: "0")
    item = ShopItem.find_by!(key: "pixel_pin")
    assert_not item.active
    assert_not_includes Prize.paid.map(&:key), "pixel_pin"
    assert_includes Prize.keys, "pixel_pin"
    get "/admin/shop?view=archived"
    assert_select "tr#item-pixel_pin"
  end

  test "the free signup item can be added only while none exists, with no price" do
    admin!
    get "/admin/shop/new"
    assert_select "select[name='shop_item[kind]']", 0, "the default sticker already exists"

    post "/admin/shop", params: item_params(key: "second_sticker", kind: "free_signup", coins: "9")
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", /already a free signup item/

    ShopItem.where(kind: "free_signup").delete_all
    get "/admin/shop/new"
    assert_select "select[name='shop_item[kind]'] option", 2
    post "/admin/shop", params: item_params(key: "welcome_sticker", kind: "free_signup", coins: "9", name: "Welcome sticker")
    created = ShopItem.find_by!(key: "welcome_sticker")
    assert_predicate created, :free_signup?
    assert_equal 0, created.coins, "the free item is free whatever the form sent"
  end

  # --- editing ---

  test "an admin edits an item's text and price; the key stays and the audit sees only the field names and coins" do
    admin!
    get "/admin/shop/tshirt/edit"
    assert_response :success
    assert_select "code", "tshirt"
    assert_select "input[name='shop_item[key]']", 0
    assert_select "input[name='shop_item[lock_version]']"
    patch "/admin/shop/tshirt", params: { shop_item: { name: "Battletown tee", coins: "60", description: "Soft.", lock_version: shop_items(:tshirt).lock_version, key: "hacked", kind: "free_signup" } }
    assert_redirected_to "/admin/shop?view=active"
    item = ShopItem.find_by!(key: "tshirt")
    assert_equal [ "Battletown tee", 60, "Soft." ], [ item.name, item.coins, item.description ]
    assert_equal "regular", item.kind
    assert_nil ShopItem.find_by(key: "hacked")
    assert_equal 1, AdminAuditEvent.count
    event = AdminAuditEvent.last
    assert_equal [ "shop_item_updated", @admin, "ShopItem", item.id ], [ event.action, event.actor, event.subject_type, event.subject_id ]
    assert_equal [ 50, 60 ], event.metadata.values_at("coins_before", "coins_after")
    assert_includes event.metadata["changed"], "name"
    assert_equal "Battletown tee", Prize.find("tshirt").name
    assert_equal 60, Prize.find("tshirt").coins
  end

  test "changing a price does not change a past order and a new order uses the new price" do
    buyer = users(:new_user)
    buyer.update_columns(onboarded_at: Time.current, onboarding_step: 4)
    verified!(buyer)
    give_coins(buyer, 300)
    old_order = buy(buyer, "tshirt")
    assert_equal 50, old_order.coins
    admin!
    patch "/admin/shop/tshirt", params: { shop_item: { coins: "80", name: "Renamed tee", lock_version: shop_items(:tshirt).lock_version } }
    assert_redirected_to "/admin/shop?view=active"

    old_order.reload
    assert_equal [ 50, "Battletown T-shirt" ], [ old_order.coins, old_order.prize_name ]
    assert_equal "Battletown T-shirt", old_order.display_name, "the order still reads as it was ordered"
    assert_equal 250, Coins::Balance.total(buyer)

    new_order = buy(buyer, "tshirt")
    assert_equal [ 80, "Renamed tee" ], [ new_order.coins, new_order.prize_name ]
    assert_equal 170, Coins::Balance.total(buyer)
    Shop::Cancel.call(order: old_order, by: @admin)
    assert_equal 220, Coins::Balance.total(buyer), "a refund gives back the price that was paid, not the new price"
  end

  test "the edit page says how many people are working toward the item and shows its orders" do
    users(:onboarded).update_columns(prize_key: "poster")
    users(:new_user).update_columns(prize_key: "poster")
    admin!
    get "/admin/shop/poster/edit"
    assert_select ".alert--warning", /2 people are working toward this/
    assert_select ".alert--warning", /Orders already made keep the price they were made at/

    get "/admin/shop/keychain/edit"
    assert_select ".alert--warning", 0
  end

  test "the price line and live preview use coins and hours only" do
    admin!
    get "/admin/shop/tshirt/edit"
    assert_select "[data-controller=shop-item-preview][data-shop-item-preview-coins-per-hour-value='10']"
    assert_select ".admin-shop-preview .shop-item .shop-item__price", "50 coins"
    assert_select "strong[data-shop-item-preview-target=hours]", "5 hours"
    assert_select ".admin-shop-preview .shop-item__name", "Battletown T-shirt"
  end

  test "an invalid edit is refused and the saved item is untouched" do
    admin!
    patch "/admin/shop/tshirt", params: { shop_item: { name: "", coins: "-3", lock_version: shop_items(:tshirt).lock_version } }
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", /Name can't be blank/
    assert_select "h1", "Edit Battletown T-shirt"
    assert_equal [ "Battletown T-shirt", 50 ], ShopItem.find_by!(key: "tshirt").then { |item| [ item.name, item.coins ] }
  end

  test "the free signup item is edited like the others but stays free and keeps its kind" do
    admin!
    get "/admin/shop/signup_sticker/edit"
    assert_select "input[name='shop_item[coins]']", 0
    assert_match(/Free: the free signup item costs no coins/, response.body)
    patch "/admin/shop/signup_sticker", params: { shop_item: { name: "Welcome sticker", coins: "40", emoji: "🎉", lock_version: shop_items(:signup_sticker).lock_version } }
    sticker = ShopItem.find_by!(key: "signup_sticker")
    assert_equal [ "Welcome sticker", 0, "free_signup" ], [ sticker.name, sticker.coins, sticker.kind ]
    assert_equal "Welcome sticker", Prize.free_signup.name
  end

  test "two admins editing the same item: the second save is told, and nothing is overwritten" do
    admin!
    get "/admin/shop/keychain/edit"
    stale_version = css_select("input[name='shop_item[lock_version]']").first["value"]
    patch "/admin/shop/keychain", params: { shop_item: { coins: "35", lock_version: stale_version } }
    assert_redirected_to "/admin/shop?view=active"

    patch "/admin/shop/keychain", params: { shop_item: { coins: "99", name: "Overwritten", lock_version: stale_version } }
    assert_redirected_to "/admin/shop/keychain/edit"
    follow_redirect!
    assert_select ".flash, .alert", /Someone else changed Keychain while you were editing/
    item = ShopItem.find_by!(key: "keychain")
    assert_equal [ "Keychain", 35 ], [ item.name, item.coins ]
    assert_select "input[name='shop_item[coins]'][value='35']"
  end

  # --- pictures ---

  test "a valid PNG or JPEG becomes a stored WebP; the form reports it and the shop serves it" do
    admin!
    [ [ "pic.png", "image/png", png_bytes(120, 60) ], [ "pic.jpg", "image/jpeg", jpeg_bytes(90, 90) ] ].each do |name, type, bytes|
      post "/admin/shop", params: item_params(key: "with_#{name.split('.').last}", image: upload_file(bytes, name: name, type: type))
      assert_redirected_to "/admin/shop"
      item = ShopItem.find_by!(key: "with_#{name.split('.').last}")
      assert_predicate item, :image?
      stored = ShopItem.image_content_for(item.key)
      assert_equal "RIFF", stored.byteslice(0, 4)
      assert_equal "WEBP", stored.byteslice(8, 4)
      assert_equal Digest::SHA256.hexdigest(stored), item.image_sha256
      assert_equal item.image_path, Prize.find(item.key).image
    end
  end

  test "a picture is shrunk to the configured size and its metadata is dropped" do
    admin!
    post "/admin/shop", params: item_params(image: upload_file(jpeg_with_gps_exif(2000, 1000), name: "phone.jpg", type: "image/jpeg"))
    item = ShopItem.find_by!(key: "pixel_pin")
    assert_equal ShopItems::Config.current.max_edge_px, item.image_width
    stored = ShopItem.image_content_for("pixel_pin")
    assert_empty webp_chunks(stored) & %w[EXIF XMP\  ICCP]
    assert_not_includes stored, "GPS"
    assert_not_includes stored, "Exif"
  end

  test "spoofed and unsafe uploads are refused whatever they claim to be, and the item is not saved" do
    admin!
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>alert(1)</script></svg>)
    {
      "SVG called PNG" => [ svg, "logo.png", "image/png" ],
      "text called JPEG" => [ "just words", "pic.jpg", "image/jpeg" ],
      "an executable called PNG" => [ "MZ\x90\x00\x03\x00\x00\x00".b + ("\x00".b * 64), "pic.png", "image/png" ],
      "an empty file" => [ "", "empty.png", "image/png" ]
    }.each do |label, (bytes, name, type)|
      assert_no_difference -> { ShopItem.count } do
        post "/admin/shop", params: item_params(image: upload_file(bytes, name: name, type: type))
      end
      assert_response :unprocessable_content, label
      assert_select ".admin-form__errors li", /The picture:/, label
    end
  end

  test "an oversized file and a pixel bomb are refused" do
    admin!
    config = ShopItems::Config.current
    assert_operator config.max_upload_bytes, :<, 5_000_000
    big = png_bytes(10, 10) + ("\0".b * (config.max_upload_bytes + 1))
    post "/admin/shop", params: item_params(image: upload_file(big))
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", /MB; the limit is 2 MB for each picture/

    bomb = png_bytes(5000, 5000)
    assert_operator bomb.bytesize, :<, config.max_upload_bytes, "a decompression bomb is tiny on the wire"
    post "/admin/shop", params: item_params(image: upload_file(bomb))
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", /too large \(25 megapixels\)/
    assert_nil ShopItem.find_by(key: "pixel_pin")
  end

  test "a field that is not a file is refused" do
    admin!
    post "/admin/shop", params: item_params(image: "<script>")
    assert_response :unprocessable_content
    assert_select ".admin-form__errors li", /wasn't a file we could read/
  end

  test "replacing a picture changes its version; removing it brings the emoji back" do
    admin!
    create_pin(image: upload_file(png_bytes(40, 40), name: "a.png"))
    first = ShopItem.without_content.find_by!(key: "pixel_pin")
    assert_predicate first, :image?

    patch "/admin/shop/pixel_pin", params: { shop_item: { image: upload_file(png_bytes(40, 40, [ 1, 2, 3 ]), name: "b.png"), lock_version: first.lock_version } }
    second = ShopItem.without_content.find_by!(key: "pixel_pin")
    assert_not_equal first.image_sha256, second.image_sha256
    assert_not_equal first.image_path, second.image_path
    assert_equal second.image_path, Prize.find("pixel_pin").image

    get "/admin/shop/pixel_pin/edit"
    assert_select "input[type=checkbox][name='shop_item[remove_image]']"
    assert_equal [ second.image_path ], css_select(".admin-shop-preview img.shop-item__image").map { |img| img["src"] }

    patch "/admin/shop/pixel_pin", params: { shop_item: { remove_image: "1", lock_version: second.lock_version } }
    removed = ShopItem.without_content.find_by!(key: "pixel_pin")
    assert_not_predicate removed, :image?
    assert_nil ShopItem.image_content_for("pixel_pin")
    assert_nil Prize.find("pixel_pin").image
  end

  test "a failed upload on an edit leaves the old picture alone" do
    admin!
    create_pin(image: upload_file(png_bytes(40, 40), name: "a.png"))
    before = ShopItem.without_content.find_by!(key: "pixel_pin")
    patch "/admin/shop/pixel_pin", params: { shop_item: { name: "Changed", image: upload_file("not a picture", name: "x.png"), lock_version: before.lock_version } }
    assert_response :unprocessable_content
    after = ShopItem.without_content.find_by!(key: "pixel_pin")
    assert_equal [ before.image_sha256, "Pixel pin" ], [ after.image_sha256, after.name ]
  end

  # --- archiving, restoring, ordering ---

  test "archive hides an item everywhere it is picked or bought but keeps its key valid; restore brings it back" do
    users(:onboarded).update_columns(prize_key: "keychain")
    admin!
    patch "/admin/shop/keychain/archive"
    assert_redirected_to "/admin/shop?view=archived"
    assert_not ShopItem.find_by!(key: "keychain").active
    assert_not_includes Prize.paid.map(&:key), "keychain"
    assert_includes Prize.keys, "keychain"
    assert_predicate users(:onboarded).reload, :valid?

    get "/admin/shop?view=archived"
    assert_select "tr#item-keychain button", text: "Restore"
    get "/admin/shop"
    assert_select "tr#item-keychain", 0

    patch "/admin/shop/keychain/restore"
    assert_redirected_to "/admin/shop?view=active"
    assert_includes Prize.paid.map(&:key), "keychain"
  end

  test "archive asks for confirmation and says how many people are working toward the item" do
    users(:onboarded).update_columns(prize_key: "keychain")
    admin!
    get "/admin/shop"
    form = css_select("tr#item-keychain form[action='/admin/shop/keychain/archive']").first
    assert_match(/1 person is working toward it/, form["data-turbo-confirm"])
    assert_match(/their pick and any orders already made keep working/, form["data-turbo-confirm"])
    get "/admin/shop/keychain/edit"
    assert_select "form[action='/admin/shop/keychain/archive'][data-turbo-confirm]"
  end

  test "archiving twice or restoring an item that is already in the shop changes nothing and says so" do
    admin!
    patch "/admin/shop/keychain/restore"
    follow_redirect!
    assert_select ".flash, .alert", /was already in the shop/
    patch "/admin/shop/keychain/archive"
    patch "/admin/shop/keychain/archive"
    follow_redirect!
    assert_select ".flash, .alert", /was already archived/
  end

  test "the Up and Down buttons swap neighbours and renumber; the ends do nothing" do
    admin!
    order = -> { ShopItem.active.in_order.pluck(:key) }
    before = order.call
    patch "/admin/shop/#{before[2]}/move", params: { direction: "up" }
    assert_redirected_to "/admin/shop?view=active#item-#{before[2]}"
    expected = before.dup
    expected[1], expected[2] = expected[2], expected[1]
    assert_equal expected, order.call
    assert_equal (1..expected.size).to_a, ShopItem.active.in_order.pluck(:position)
    assert_equal expected.reject { |key| ShopItem.find_by!(key: key).free_signup? }, Prize.paid.map(&:key)

    patch "/admin/shop/#{expected.first}/move", params: { direction: "up" }
    follow_redirect!
    assert_select ".flash, .alert", /already at the top/
    patch "/admin/shop/#{expected.last}/move", params: { direction: "down" }
    follow_redirect!
    assert_select ".flash, .alert", /already at the bottom/
    assert_equal expected, order.call

    patch "/admin/shop/#{expected.first}/move", params: { direction: "sideways" }
    assert_redirected_to "/admin/shop?view=active"
    assert_equal expected, order.call
  end

  test "the first item's Up button and the last item's Down button are disabled" do
    admin!
    get "/admin/shop"
    rows = css_select("tbody tr")
    assert_select rows.first, "button[disabled]", text: "Up"
    assert_select rows.last, "button[disabled]", text: "Down"
    assert_select rows[1], "button[disabled]", 0
  end

  test "order on the shop, the landing page and the onboarding picker follows the positions staff set" do
    admin!
    first = Prize.paid.first.key
    patch "/admin/shop/#{first}/move", params: { direction: "down" }
    expected = Prize.paid.map(&:key)
    assert_equal first, expected[1]

    delete logout_path
    get "/"
    assert_equal expected, css_select(".prize h3").map(&:text).map { |name| Prize.paid.find { |prize| prize.name == name }.key }
  end

  # --- audit ---

  test "every mutation is audited with a known action, on the item, by the admin, with no personal data" do
    admin!
    post "/admin/shop", params: item_params
    patch "/admin/shop/pixel_pin", params: { shop_item: { coins: "26", lock_version: 0 } }
    patch "/admin/shop/pixel_pin/move", params: { direction: "up" }
    patch "/admin/shop/pixel_pin/archive"
    patch "/admin/shop/pixel_pin/restore"
    item = ShopItem.find_by!(key: "pixel_pin")
    events = AdminAuditEvent.order(:id).to_a
    assert_equal %w[shop_item_created shop_item_updated shop_item_reordered shop_item_archived shop_item_restored], events.map(&:action)
    assert_empty events.map(&:action) - AdminAudit::SHOP_ACTIONS
    assert(events.all? { |event| event.actor == @admin && event.subject_type == "ShopItem" && event.subject_id == item.id })
    assert_equal({ "coins" => 25, "kind" => "regular", "active" => true, "picture" => false }, events[0].metadata)
    assert_equal({ "changed" => "coins", "coins_before" => 25, "coins_after" => 26 }, events[1].metadata)
    assert_equal({ "direction" => "up" }, events[2].metadata)
    assert_equal({}, events[3].metadata)
  end

  test "a picture edit is audited as a field name, never the picture" do
    admin!
    patch "/admin/shop/tshirt", params: { shop_item: { image: upload_file(png_bytes(40, 40)), lock_version: shop_items(:tshirt).lock_version } }
    assert_equal({ "changed" => "picture" }, AdminAuditEvent.last.metadata)
  end

  test "failed saves, no-op moves and unchanged saves are not audited" do
    admin!
    post "/admin/shop", params: item_params(name: "")
    patch "/admin/shop/#{Prize.paid.first.key}/move", params: { direction: "up" }
    patch "/admin/shop/tshirt", params: { shop_item: { name: "Battletown T-shirt", lock_version: shop_items(:tshirt).lock_version } }
    patch "/admin/shop/keychain/restore"
    assert_equal 0, AdminAuditEvent.count
  end

  test "an audit failure rolls the change back" do
    admin!
    AdminAudit.singleton_class.prepend(Module.new { def record!(**) = raise("audit down") })
    begin
      assert_raises(RuntimeError) { patch "/admin/shop/tshirt/archive" }
    ensure
      AdminAudit.singleton_class.ancestors.first.send(:remove_method, :record!)
    end
    assert ShopItem.find_by!(key: "tshirt").active
  end

  # --- the catalogue is not set up yet ---

  test "with no rows the list explains how to load the defaults" do
    ShopItem.delete_all
    admin!
    get "/admin/shop"
    assert_response :success
    assert_select ".alert--warning", /shop_items:import/
  end
end
