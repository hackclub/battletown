require "test_helper"
require_relative "../support/bosses_helper"
require_relative "../support/ship_images_helper"
require_relative "../support/admin_sign_in"

# GET /bosses/:id/art: a boss's own picture, public like the shop item pictures (BossArtsController).
class BossArtsTest < ActionDispatch::IntegrationTest
  include BossesHelper
  include ShipImagesHelper
  include AdminSignIn

  setup do
    @processed = ShipImages::Processor.call(upload_file(png_bytes(64, 32)), config: Bosses::ArtConfig.current)
    @boss = make_boss
    @boss.attach_art(@processed)
    @boss.art_alt = "A tall boss"
    @boss.save!
  end

  test "the picture is served to anyone, as a WebP, with a private day-long cache and an ETag" do
    get @boss.art_path
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

  test "no login is needed and no cookie is set" do
    get @boss.art_path
    assert_response :success
    assert_nil response.headers["Set-Cookie"]
    assert_empty cookies.to_hash
  end

  test "a repeat request with the ETag gets a 304 and no body" do
    get @boss.art_path
    etag = response.headers["ETag"]
    get @boss.art_path, headers: { "If-None-Match" => etag }
    assert_response :not_modified
    assert_empty response.body
  end

  test "a replaced picture has a new version in its URL and a new ETag" do
    first_path = @boss.art_path
    get first_path
    first_etag = response.headers["ETag"]
    replacement = ShipImages::Processor.call(upload_file(png_bytes(64, 32, [ 9, 9, 200 ])), config: Bosses::ArtConfig.current)
    @boss.attach_art(replacement)
    @boss.save!
    assert_not_equal first_path, @boss.art_path
    get @boss.art_path
    assert_not_equal first_etag, response.headers["ETag"]
    assert_equal replacement.content, response.body.b
  end

  test "the URL works without the version parameter too" do
    get "/bosses/#{@boss.id}/art"
    assert_response :success
    assert_equal "image/webp", response.media_type
  end

  test "a boss with no picture, an unknown id and a badly formed id are all a plain 404" do
    get "/bosses/#{make_boss(starts_on: FRIDAY + 7).id}/art"
    assert_response :not_found
    get "/bosses/0/art"
    assert_response :not_found
    get "/bosses/#{'9' * 30}/art"
    assert_response :not_found
    get "/bosses/abc/art"
    assert_response :not_found
    assert_empty response.body.to_s.scan(/ActiveRecord|RecordNotFound/)
  end

  test "the picture of a boss that has not begun is for staff only" do
    upcoming = make_boss(starts_on: Date.new(2030, 1, 4))
    upcoming.attach_art(@processed)
    upcoming.art_alt = "Next week's boss"
    upcoming.save!
    get upcoming.art_path
    assert_response :not_found

    sign_in_as users(:onboarded)
    get upcoming.art_path
    assert_response :not_found, "a signed-in non-admin sees nothing either"

    as_admin(users(:onboarded))
    get upcoming.art_path
    assert_response :success
  end

  test "a boss's picture is public from the first moment its first day has begun anywhere" do
    upcoming = make_boss(starts_on: Date.new(2030, 1, 4))
    upcoming.attach_art(@processed)
    upcoming.art_alt = "Next week's boss"
    upcoming.save!
    travel_to Time.utc(2030, 1, 3, 9, 59) do # 23:59 on Thursday in UTC+14
      get upcoming.art_path
      assert_response :not_found
    end
    travel_to Time.utc(2030, 1, 3, 10, 0) do # midnight on Friday in UTC+14
      get upcoming.art_path
      assert_response :success
    end
  end

  test "a boss whose picture was removed is a 404 again" do
    path = @boss.art_path
    @boss.remove_art
    @boss.save!
    get path
    assert_response :not_found
  end

  test "the route takes no format suffix and no other verb" do
    get "/bosses/#{@boss.id}/art.png"
    assert_response :not_found
    post "/bosses/#{@boss.id}/art"
    assert_response :not_found
  end

  test "the response carries no personal data and the URL is same-origin" do
    get @boss.art_path
    assert_no_match(/hca_uid|display_name|slack/i, response.headers.to_h.inspect)
    assert_match(%r{\A/bosses/\d+/art\?v=\h{12}\z}, @boss.art_path)
  end

  test "the bytes are read once for the picture, not for the lookup" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] if payload[:sql].include?("art_content") }
    get @boss.art_path
    ActiveSupport::Notifications.unsubscribe(subscriber)
    assert_equal 1, statements.size
  end
end
