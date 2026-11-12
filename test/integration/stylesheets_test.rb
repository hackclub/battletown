require "test_helper"

# The foundation stylesheets and design images must exist, be served through Propshaft (digested, same origin) and
# every url() in them must resolve; a missing file here would break every page. The real compile is also checked by
# `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile` (see docs/CONTRACT.md, "Design system").
class StylesheetsTest < ActionDispatch::IntegrationTest
  STYLESHEETS = Rails.root.join("app/assets/stylesheets")
  DESIGN_IMAGES = Rails.root.join("app/assets/images/design")

  test "the foundation stylesheets exist and are in the Propshaft load path" do
    %w[tokens.css application.css components.css fonts.css staff.css styleguide.css].each do |name|
      assert STYLESHEETS.join(name).exist?, "#{name} is missing"
      assert Rails.application.assets.load_path.find(name), "#{name} is not in the asset load path"
    end
  end

  test "the layout links every stylesheet in app/assets/stylesheets (digested, same origin)" do
    get root_path
    hrefs = css_select("link[rel=stylesheet]").map { |link| link["href"] }
    assert_equal Dir[STYLESHEETS.join("*.css")].size, hrefs.size
    assert(hrefs.all? { |href| href.start_with?("/assets/") && href.match?(/-[0-9a-f]{8,}\.css\z/) }, hrefs.inspect)
    assert(hrefs.any? { |href| href.include?("components-") })
    assert(hrefs.any? { |href| href.include?("tokens-") })
  end

  test "every url() in a stylesheet resolves to a real asset" do
    Dir[STYLESHEETS.join("*.css")].each do |path|
      File.read(path).scan(/url\(\s*["']?([^"')]+)["']?\s*\)/).flatten.each do |target|
        next if target.start_with?("data:", "http", "#", "/")

        assert Rails.application.assets.load_path.find(target), "#{File.basename(path)} refers to #{target}, which is not an asset"
      end
    end
  end

  test "the design images are present, small and safe (no scripts, handlers or external references in SVGs)" do
    files = Dir[DESIGN_IMAGES.join("*")].reject { |path| File.basename(path) == "README.md" }
    assert_operator files.size, :>=, 15
    assert_operator files.sum { |path| File.size(path) }, :<, 1_500_000, "design assets must stay under about 1.5 MB"
    files.grep(/\.svg\z/).each do |path|
      svg = File.read(path)
      assert_no_match(/<script|<foreignObject|<iframe|<image|\son[a-z]+\s*=|@import/i, svg, path)
      assert_no_match(/(?:href|src)\s*=\s*["'](?!#)/i, svg, "#{path} has an external reference")
      assert_no_match(%r{url\(\s*["']?(?:https?:|//)}i, svg, "#{path} has an external reference")
    end
  end

  test "every design image is documented in its README" do
    readme = DESIGN_IMAGES.join("README.md").read
    Dir[DESIGN_IMAGES.join("*")].map { |path| File.basename(path) }.reject { |name| name == "README.md" }.each do |name|
      assert_includes readme, "`#{name}`", "#{name} is not listed in app/assets/images/design/README.md"
    end
  end
end
