require "test_helper"
require_relative "../support/ship_images_helper"

# Rate limits and the early size check on /admin/shop (config/initializers/rack_attack.rb). They sit in front of the app, so they
# apply to anyone who can reach the path, signed in or not.
class AdminShopLimitsTest < ActionDispatch::IntegrationTest
  include ShipImagesHelper

  WINDOW_START = Time.utc(2030, 1, 1, 12, 0, 0)

  setup do
    travel_to WINDOW_START
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
  end

  teardown do
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
    travel_back
  end

  test "writes under /admin/shop are limited to 60 a minute per address" do
    60.times { patch "/admin/shop/tshirt/archive", headers: { "REMOTE_ADDR" => "203.0.113.50" } }
    assert_not_equal 429, response.status
    patch "/admin/shop/tshirt/archive", headers: { "REMOTE_ADDR" => "203.0.113.50" }
    assert_response :too_many_requests
    post "/admin/shop", headers: { "REMOTE_ADDR" => "203.0.113.50" }
    assert_response :too_many_requests
    patch "/admin/shop/tshirt/archive", headers: { "REMOTE_ADDR" => "203.0.113.51" }
    assert_not_equal 429, response.status
  end

  test "reading the admin shop pages is not part of that limit" do
    70.times { get "/admin/shop", headers: { "REMOTE_ADDR" => "203.0.113.52" } }
    assert_not_equal 429, response.status
  end

  test "a picture upload bigger than the limit is refused with a 413 before Rails reads it" do
    limit = ShopItems::Config.current.max_request_bytes
    big = upload_file("RIFF".b + ("a".b * (limit + 10)), name: "big.png")
    post "/admin/shop", params: { shop_item: { key: "big_one", name: "Big", coins: "5", image: big } }, headers: { "REMOTE_ADDR" => "203.0.113.53" }
    assert_response :content_too_large
    assert_includes response.body, "That picture is too big"
    assert_equal 0, ShopItem.where(key: "big_one").count
  end

  test "an upload within the limit is not stopped by the size check (the admin check then answers 404)" do
    post "/admin/shop", params: { shop_item: { key: "ok_one", name: "Ok", coins: "5", image: upload_file(png_bytes(30, 30), name: "ok.png") } },
                        headers: { "REMOTE_ADDR" => "203.0.113.54" }
    assert_response :not_found
  end

  test "a multipart body with no Content-Length is refused too" do
    post "/admin/shop", headers: { "REMOTE_ADDR" => "203.0.113.55", "CONTENT_TYPE" => "multipart/form-data; boundary=x", "CONTENT_LENGTH" => nil },
                        params: "--x--\r\n"
    assert_response :content_too_large
  end

  test "the size check does not touch other paths" do
    request = lambda do |path, method|
      Rack::Request.new("REQUEST_METHOD" => method, "PATH_INFO" => path, "SCRIPT_NAME" => "", "CONTENT_TYPE" => "multipart/form-data; boundary=x")
    end
    assert_not Rack::Attack.shop_upload?(request.call("/admin/shops", "POST"))
    assert_not Rack::Attack.shop_upload?(request.call("/shop/orders", "POST"))
    assert_not Rack::Attack.shop_upload?(request.call("/admin/shop/tshirt", "GET"))
    assert Rack::Attack.shop_upload?(request.call("/admin/shop/tshirt", "PATCH"))
    assert Rack::Attack.shop_upload?(request.call("/admin/shop/", "POST"))
  end
end
