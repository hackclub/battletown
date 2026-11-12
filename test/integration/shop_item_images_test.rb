require "test_helper"
require_relative "../support/ship_images_helper"

class ShopItemImagesTest < ActionDispatch::IntegrationTest
  include ShipImagesHelper

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @processed = ShipImages::Processor.call(upload_file(png_bytes(64, 32)), config: ShopItems::Config.current)
    @item = shop_items(:poster)
    @item.attach_image(@processed)
    @item.save!
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  test "the picture is served to anyone, as a WebP, with a private day-long cache and an ETag" do
    get @item.image_path
    assert_response :success
    assert_equal "image/webp", response.media_type
    assert_equal @processed.content, response.body.b
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "sandbox", response.headers["Content-Security-Policy"]
    assert_equal "inline", response.headers["Content-Disposition"].to_s.split(";").first
    cache = response.headers["Cache-Control"].to_s
    assert_includes cache, "max-age=86400"
    assert_includes cache, "private"
    assert_not_includes cache, "public"
    assert_predicate response.headers["ETag"], :present?
  end

  test "a repeat request with the ETag gets a 304 and no body" do
    get @item.image_path
    etag = response.headers["ETag"]
    get @item.image_path, headers: { "If-None-Match" => etag }
    assert_response :not_modified
    assert_empty response.body
  end

  test "a replaced picture has a new version in its URL and a new ETag" do
    first_path = @item.image_path
    get first_path
    first_etag = response.headers["ETag"]
    replacement = ShipImages::Processor.call(upload_file(png_bytes(64, 32, [ 9, 9, 200 ])), config: ShopItems::Config.current)
    @item.attach_image(replacement)
    @item.save!
    assert_not_equal first_path, @item.image_path
    get @item.image_path
    assert_not_equal first_etag, response.headers["ETag"]
    assert_equal replacement.content, response.body.b
  end

  test "the URL works without the version parameter too" do
    get "/shop/items/poster/image"
    assert_response :success
    assert_equal "image/webp", response.media_type
  end

  test "an item with no picture, an unknown key and a badly formed key are all a plain 404" do
    get "/shop/items/tshirt/image"
    assert_response :not_found
    get "/shop/items/nope/image"
    assert_response :not_found
    get "/shop/items/Bad-Key/image"
    assert_response :not_found
    get "/shop/items/#{'a' * 61}/image"
    assert_response :not_found
  end

  test "the image route does not take a format suffix or other verbs" do
    get "/shop/items/poster/image.png"
    assert_response :not_found
    post "/shop/items/poster/image"
    assert_response :not_found
  end

  test "an archived item's picture is for staff only" do
    @item.update!(active: false)
    get @item.image_path
    assert_response :not_found

    sign_in_as users(:onboarded)
    get @item.image_path
    assert_response :not_found, "a signed-in non-admin sees nothing either"

    ENV["ADMIN_HCA_UIDS"] = users(:onboarded).hca_uid
    get @item.image_path
    assert_response :success
    assert_equal "image/webp", response.media_type
  end

  test "restoring the item makes the picture public again" do
    @item.update!(active: false)
    @item.update!(active: true)
    get @item.image_path
    assert_response :success
  end

  test "the response carries no personal data" do
    get @item.image_path
    assert_no_match(/hca_uid|display_name|slack/i, response.headers.to_h.inspect)
  end

  test "the picture URL is same-origin, so the CSP's img-src self covers it" do
    assert_match(%r{\A/shop/items/[a-z0-9_]+/image\?v=\h{12}\z}, @item.image_path)
  end
end
