require "test_helper"

# The static error pages are served as-is (outside the app's CSP middleware), so they must not
# need inline scripts or styles; all styling comes from the same-origin /error.css.
class ErrorPagesTest < ActiveSupport::TestCase
  PAGES = %w[400 404 406-unsupported-browser 422 500].freeze

  def page_html(name) = Rails.public_path.join("#{name}.html").read

  # Production serves public/ with a one-year cache, so the pages ask for error.css?v=<first 8 hex of its SHA-256>:
  # change the stylesheet and the URL changes, so returning visitors never see old CSS with new markup.
  def error_css_version = Digest::SHA256.hexdigest(Rails.public_path.join("error.css").read)[0, 8]

  test "the error pages request error.css by a version that matches the file" do
    PAGES.each do |code|
      versions = page_html(code).scan(%r{href="/error\.css\?v=(\h+)"}).flatten
      assert_equal [ error_css_version ], versions,
                   "#{code}.html: error.css changed? Update every public/*.html link to /error.css?v=#{error_css_version}"
    end
  end

  test "error pages exist, link the same-origin stylesheet and use no inline script or style" do
    assert Rails.public_path.join("error.css").file?
    PAGES.each do |code|
      html = page_html(code)
      assert_includes html, "<title>", "#{code}.html needs a title"
      assert_includes html, "BattleTown</title>", "#{code}.html title ends with the brand"
      assert_includes html, "Battletown", "#{code}.html should be branded"
      assert_includes html, %(href="/error.css?v=#{error_css_version}"), "#{code}.html should link /error.css?v=#{error_css_version} (see the versioned stylesheet test)"
      assert_includes html, 'href="/"', "#{code}.html should link home"
      assert_no_match(/<script/i, html, "#{code}.html has a script tag")
      assert_no_match(/<style/i, html, "#{code}.html has a style tag")
      assert_no_match(/style\s*=/i, html, "#{code}.html has an inline style")
      assert_no_match(/\bon\w+\s*=/i, html, "#{code}.html has an inline event handler")
      assert_no_match(%r{(src|href)\s*=\s*["']?(https?:)?//}i, html, "#{code}.html loads an external asset")
    end
  end

  test "each error page is a complete, accessible document" do
    PAGES.each do |code|
      doc = Nokogiri::HTML5(page_html(code))
      assert_equal "en", doc.at("html")["lang"], code
      assert doc.at("meta[name=viewport]"), "#{code} needs a viewport"
      assert_equal 1, doc.css("h1").size, "#{code} needs exactly one h1"
      assert_equal 1, doc.css("main").size, "#{code} needs a main landmark"
      assert doc.at("a.cta[href='/']"), "#{code} needs a way home"
      assert doc.at("p.code")&.text.to_s.match?(/\AError \d{3}\z/), "#{code} should show its status code"
      doc.css("img").each { |img| assert img.key?("alt"), "#{code} img #{img['src']} has no alt" }
      assert_equal "Battletown", doc.at("a.brand img")["alt"]
      assert_equal "", doc.at("img.scene")["alt"], "the scene is decoration"
      assert_equal "true", doc.at("svg.cta__arrow")["aria-hidden"]
    end
  end

  test "every file an error page or error.css points at exists in public" do
    refs = PAGES.flat_map { |code| page_html(code).scan(/(?:src|href)="(\/[^"?]*)(?:\?[^"]*)?"/).flatten }
    refs += Rails.public_path.join("error.css").read.scan(/url\("(\/[^"]+)"\)/).flatten
    refs.uniq.reject { |ref| ref == "/" }.each do |ref|
      assert Rails.public_path.join(ref.delete_prefix("/")).file?, "#{ref} is missing from public/"
    end
    assert_includes refs, "/error-fonts/poetsen-one-400.woff2"
  end

  test "error.css only uses colours from the design tokens" do
    tokens = Rails.root.join("app/assets/stylesheets/tokens.css").read.scan(/#\h{3,6}\b/).map(&:downcase).to_set
    used = Rails.public_path.join("error.css").read.scan(/#\h{6}\b/).map(&:downcase).uniq
    assert_empty used - tokens.to_a, "error.css has colours that are not in tokens.css"
  end

  test "error.css loads no external resource and the art files carry no script" do
    css = Rails.public_path.join("error.css").read
    assert_no_match(%r{url\(\s*["']?(https?:)?//}i, css)
    assert_no_match(/@import/i, css)
    %w[error-logo.svg error-scene.svg].each do |file|
      svg = Rails.public_path.join(file).read
      assert_no_match(/<script|<foreignObject|\son[a-z]+\s*=|(?:href|src)\s*=\s*["'](?!#)/i, svg, file) # only internal #id references
    end
  end
end
