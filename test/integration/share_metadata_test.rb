require "test_helper"
require "vips"

# Link previews and the brand: the head tags every page carries (description, Open Graph, Twitter, theme colour), the
# icons and the 1200x630 share image in public/, the web app manifest, and "Battletown" (one word) everywhere.
class ShareMetadataTest < ActionDispatch::IntegrationTest
  APP_URL = "https://battletown.example".freeze

  setup do
    @old_app_url = ENV["APP_URL"]
    ENV["APP_URL"] = "#{APP_URL}/"
  end

  teardown do
    ENV["APP_URL"] = @old_app_url
  end

  def meta(selector) = css_select(selector).first&.[]("content")

  def image_size(path)
    image = Vips::Image.new_from_file(Rails.public_path.join(path.delete_prefix("/")).to_s)
    [ image.width, image.height ]
  end

  test "the landing page has the description, Open Graph and Twitter tags with absolute URLs" do
    get "/"
    assert_response :success
    assert_select "title", text: "Battletown", count: 1
    assert_match(/free Hack Club .*program for teens/, meta("meta[name=description]"))
    assert_equal meta("meta[name=description]"), meta("meta[property='og:description']")
    assert_equal meta("meta[name=description]"), meta("meta[name='twitter:description']")
    assert_equal "Battletown: build projects, fight the weekly boss, earn prizes", meta("meta[property='og:title']")
    assert_equal "website", meta("meta[property='og:type']")
    assert_equal "Battletown", meta("meta[property='og:site_name']")
    assert_equal "#{APP_URL}/", meta("meta[property='og:url']"), "the trailing slash on APP_URL is dropped, the path added"
    assert_equal "#{APP_URL}/og-image.png", meta("meta[property='og:image']")
    assert_equal "#{APP_URL}/og-image.png", meta("meta[name='twitter:image']")
    assert_equal "1200", meta("meta[property='og:image:width']")
    assert_equal "630", meta("meta[property='og:image:height']")
    assert_predicate meta("meta[property='og:image:alt']"), :present?
    assert_equal "summary_large_image", meta("meta[name='twitter:card']")
    assert_equal "#1472d5", meta("meta[name=theme-color]")
  end

  test "other pages share their own title and URL and fall back to the default description" do
    get "/onboarding/age"
    assert_response :success
    assert_equal "How old are you? - Battletown", meta("meta[property='og:title']")
    assert_equal "#{APP_URL}/onboarding/age", meta("meta[property='og:url']")
    assert_equal ApplicationController.helpers.default_meta_description, meta("meta[name=description]")
    assert_equal 1, css_select("meta[name=description]").size
  end

  test "the head links the favicon set, the touch icon and the manifest, and each file is there" do
    get "/"
    hrefs = css_select("head link[rel~=icon], head link[rel=apple-touch-icon], head link[rel=manifest]").map { |l| l["href"] }
    assert_equal %w[/manifest.json /favicon.ico /icon-32.png /icon-180.png], hrefs
    (hrefs - [ "/manifest.json" ]).each { |href| assert Rails.public_path.join(href.delete_prefix("/")).file?, "#{href} is missing from public/" }
  end

  test "the icons and the share image have the right dimensions" do
    { "/icon-32.png" => [ 32, 32 ], "/icon-180.png" => [ 180, 180 ], "/icon-192.png" => [ 192, 192 ],
      "/icon.png" => [ 512, 512 ], "/icon-maskable.png" => [ 512, 512 ], "/og-image.png" => [ 1200, 630 ] }.each do |path, size|
      assert_equal size, image_size(path), "#{path} should be #{size.join('x')}"
    end
  end

  test "/favicon.ico answers to a signed-out visitor as a real .ico holding 16, 32 and 48 px images" do
    get "/favicon.ico"
    assert_response :success
    body = response.body.b
    assert_equal [ 0, 1 ], body.unpack("v2"), "not an ICO header (reserved 0, type 1)"
    count = body.unpack1("@4v")
    sizes = (0...count).map { |i| body.byteslice(6 + 16 * i, 2).bytes.map { |b| b.zero? ? 256 : b } }
    assert_equal [ [ 16, 16 ], [ 32, 32 ], [ 48, 48 ] ], sizes
    assert_operator body.bytesize, :<, 50_000
  end

  test "the icon files are real images by their magic bytes and stay small" do
    %w[icon-32.png icon-180.png icon-192.png icon.png icon-maskable.png].each do |name|
      path = Rails.public_path.join(name)
      assert_equal "\x89PNG\r\n\x1a\n".b, path.binread(8), "#{name} is not a PNG"
      assert_operator path.size, :<, 100_000, "#{name} is too big for an icon"
    end
  end

  test "the touch and maskable icons sit on a solid background (iOS paints transparency black) and the rest keep their alpha" do
    color_type = ->(name) { Rails.public_path.join(name).binread(26).getbyte(25) } # PNG IHDR colour type: 2 is RGB, 6 is RGBA
    %w[icon-180.png icon-maskable.png].each { |name| assert_equal 2, color_type.(name), "#{name} should be opaque" }
    %w[icon-32.png icon-192.png icon.png].each { |name| assert_equal 6, color_type.(name), "#{name} should keep its transparency" }
  end

  test "the manifest names Battletown, uses the brand colours and lists icons that exist at their stated sizes" do
    get "/manifest.json"
    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "Battletown", manifest["name"]
    assert_equal "Battletown", manifest["short_name"]
    assert_equal "#1472d5", manifest["theme_color"]
    assert_equal "#b1dcfe", manifest["background_color"]
    assert_operator manifest["icons"].size, :>=, 2
    manifest["icons"].each do |icon|
      assert_equal icon["sizes"].split("x").map(&:to_i), image_size(icon["src"]), "#{icon['src']} is not #{icon['sizes']}"
    end
    assert_includes manifest["icons"].map { |i| i["purpose"] }, "maskable"
  end

  test "the brand is Battletown, one word, in every view, helper, page and the static error pages" do
    files = Dir[Rails.root.join("app/**/*.{rb,erb,yml,js}"), Rails.root.join("config/**/*.yml"), Rails.public_path.join("*.html")]
    assert_operator files.size, :>, 100
    files.each do |file|
      text = File.read(file)
      assert_no_match(/BattleTown|Battle Town|Battle town|battle town/, text, "#{file.delete_prefix("#{Rails.root}/")} spells the brand wrongly")
    end
  end

  test "the sticker claim heading keeps Battletown capitalised" do
    OmniAuth.config.test_mode = true
    user = users(:onboarded)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
    get new_shop_sticker_path
    assert_response :success
    assert_select "h1", text: "Claim your free Battletown sticker?"
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end
end
