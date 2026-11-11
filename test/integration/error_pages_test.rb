require "test_helper"

# The static error pages are served as-is (outside the app's CSP middleware), so they must not
# need inline scripts or styles; all styling comes from the same-origin /error.css.
class ErrorPagesTest < ActiveSupport::TestCase
  PAGES = %w[404 422 500].freeze

  test "error pages exist, link the same-origin stylesheet and use no inline script or style" do
    assert Rails.public_path.join("error.css").file?
    PAGES.each do |code|
      html = Rails.public_path.join("#{code}.html").read
      assert_includes html, "<title>", "#{code}.html needs a title"
      assert_includes html, "Battletown", "#{code}.html should be branded"
      assert_includes html, 'href="/error.css"', "#{code}.html should link /error.css"
      assert_includes html, 'href="/"', "#{code}.html should link home"
      assert_no_match(/<script/i, html, "#{code}.html has a script tag")
      assert_no_match(/<style/i, html, "#{code}.html has a style tag")
      assert_no_match(/style\s*=/i, html, "#{code}.html has an inline style")
      assert_no_match(%r{(src|href)\s*=\s*["']?(https?:)?//}i, html, "#{code}.html loads an external asset")
    end
  end
end
