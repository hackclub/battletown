require "test_helper"
require_relative "../support/ship_images_helper"

# Rate limits and the early size check on /admin/bosses (config/initializers/rack_attack.rb). They sit in front of the app, so they
# apply to anyone who can reach the path, signed in or not.
class AdminBossLimitsTest < ActionDispatch::IntegrationTest
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

  test "writes under /admin/bosses are limited to 60 a minute per address" do
    60.times { patch "/admin/bosses/1", headers: { "REMOTE_ADDR" => "203.0.113.60" } }
    assert_not_equal 429, response.status
    patch "/admin/bosses/1", headers: { "REMOTE_ADDR" => "203.0.113.60" }
    assert_response :too_many_requests
    post "/admin/bosses", headers: { "REMOTE_ADDR" => "203.0.113.60" }
    assert_response :too_many_requests
    patch "/admin/bosses/1", headers: { "REMOTE_ADDR" => "203.0.113.61" }
    assert_not_equal 429, response.status
  end

  test "reading the admin boss pages is not part of that limit" do
    70.times { get "/admin/bosses", headers: { "REMOTE_ADDR" => "203.0.113.62" } }
    assert_not_equal 429, response.status
  end

  test "a picture upload bigger than the limit is refused with a 413 before Rails reads it, on create and on update" do
    limit = Bosses::ArtConfig.current.max_request_bytes
    big = upload_file("RIFF".b + ("a".b * (limit + 10)), name: "big.png")
    post "/admin/bosses", params: { boss: { name: "Big", hp_hours: "5", starts_on: "2030-01-04", art_upload: big } }, headers: { "REMOTE_ADDR" => "203.0.113.63" }
    assert_response :content_too_large
    assert_includes response.body, "That picture is too big"
    assert_equal 0, Boss.where(name: "Big").count

    patch "/admin/bosses/1", params: { boss: { name: "Big", art_upload: upload_file("RIFF".b + ("a".b * (limit + 10)), name: "big2.png") } }, headers: { "REMOTE_ADDR" => "203.0.113.64" }
    assert_response :content_too_large
  end

  test "an upload within the limit is not stopped by the size check (the admin check then answers 404)" do
    post "/admin/bosses", params: { boss: { name: "Ok", hp_hours: "5", starts_on: "2030-01-04", art_upload: upload_file(png_bytes(30, 30), name: "ok.png") } },
                          headers: { "REMOTE_ADDR" => "203.0.113.65" }
    assert_response :not_found
  end

  test "a percent-encoded id or a multipart/mixed body does not get around the size check or the write limit" do
    limit = Bosses::ArtConfig.current.max_request_bytes
    body = "--x\r\n" + ("a" * (limit + 10)) + "\r\n--x--\r\n"
    patch "/admin/bosses/%31", headers: { "REMOTE_ADDR" => "203.0.113.66", "CONTENT_TYPE" => "multipart/form-data; boundary=x" }, params: body
    assert_response :content_too_large
    get "/admin/bosses/%31/edit"
    assert_not_equal 413, response.status
    patch "/admin/bosses/1", headers: { "REMOTE_ADDR" => "203.0.113.67", "CONTENT_TYPE" => "multipart/mixed; boundary=x" }, params: body
    assert_response :content_too_large
    post "/admin/bosses", headers: { "REMOTE_ADDR" => "203.0.113.68", "CONTENT_TYPE" => "multipart/related; boundary=x", "CONTENT_LENGTH" => nil }, params: "--x--\r\n"
    assert_response :content_too_large

    60.times { patch "/admin/bosses/%31", headers: { "REMOTE_ADDR" => "203.0.113.69" } }
    patch "/admin/bosses/%31", headers: { "REMOTE_ADDR" => "203.0.113.69" }
    assert_response :too_many_requests
  end
end
