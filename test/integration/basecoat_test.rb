require "test_helper"

# Tailwind + Basecoat (app/assets/tailwind/): built into vendor/assets/builds/tailwind.css, loaded only by layouts/basecoat
# (/dev/basecoat, development only), never by `stylesheet_link_tag :app`. The theme maps Basecoat's variables onto tokens.css.
class BasecoatTest < ActionDispatch::IntegrationTest
  THEME = Rails.root.join("app/assets/tailwind/battletown_theme.css")

  def in_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  setup do
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
  end

  teardown { Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed }

  test "the demo page is a 404 in test and production, like the style guide" do
    get "/dev/basecoat"
    assert_response :not_found

    %w[test production].each do |env|
      in_env(env) do
        get "/dev/basecoat"
        assert_response :not_found, env
      end
    end
  end

  test "the Tailwind build is never linked by the site layout and its sources stay out of app/assets/stylesheets" do
    get root_path
    assert_select "link[rel=stylesheet][href*=tailwind]", 0
    assert_select "link[rel=stylesheet][href*=basecoat]", 0
    assert_empty Dir[Rails.root.join("app/assets/builds/*.css")], "build output in app/assets/builds would be linked on every page"
    assert_empty Dir[Rails.root.join("app/assets/stylesheets/*{tailwind,basecoat}*")]
  end

  test "the theme points at tokens.css and copies no color" do
    css = THEME.read
    theme = css.gsub(%r{/\*.*?\*/}m, "").gsub(/url\('data:[^']*'\)/, "") # comments, and the data-URI icons that cannot read custom properties
    assert_empty theme.scan(/#\h{3,8}\b/), "use var(--color-...) tokens, not hex values"
    assert_empty theme.gsub(/rgb\(0 0 0 \/ [\d.]+\)/, "").scan(/\brgba?\(|\bhsla?\(|\boklch\(/) # black hover steps, as components.css has

    referenced = theme.scan(/var\((--(?:color|radius|font|text|leading|edge)[a-z0-9-]*)\)/).flatten.uniq
    # names this file defines itself for Tailwind, or that Tailwind and Basecoat supply
    own = theme.scan(/^\s*(--[a-z0-9-]+)\s*:/).flatten
    missing = referenced.reject { |name| DesignSystem::Tokens.find(name) || own.include?(name) }
    assert_empty missing, "the theme refers to tokens that tokens.css does not define"
  end

  test "the house rules are in the theme: white on pink, flat fills, hard shadows only, no gradients" do
    css = THEME.read.gsub(%r{/\*.*?\*/}m, "")
    assert_match(/--primary:\s*var\(--color-primary\)/, css)
    assert_match(/--primary-foreground:\s*var\(--color-surface\)/, css)
    assert_equal "#ffffff", DesignSystem::Tokens.resolve("--color-surface")
    assert_no_match(/--primary-foreground:\s*var\(--color-primary-contrast\)/, css, "cream text on pink; the owner wants white")
    assert_no_match(/gradient\(/, css)
    # every box-shadow is hard: an inset fill, none, or offsets with a zero blur
    css.scan(/box-shadow:\s*([^;]+);/).flatten.each do |shadow|
      assert(shadow.start_with?("inset", "none") || shadow.match?(/\A(?:0|0?\.?\d*rem) (?:0?\.?\d+rem) 0 /) || shadow.match?(/\A0\.25rem 0\.25rem 0 /), "soft or odd shadow: #{shadow}")
    end
    assert_match(/option-row:has\(> input:checked\)[^}]*background: var\(--color-blue\)[^}]*color: var\(--color-surface\)/, css, "a picked option is solid blue with white text")
  end

  test "the chevron icon is drawn in the muted text color" do
    muted = DesignSystem::Tokens.resolve("--color-text-muted").delete("#")
    assert_includes THEME.read, "stroke=\"%23#{muted}\""
  end

  test "the demo view uses no inline style or script, so the CSP keeps working" do
    view = Rails.root.join("app/views/dev/basecoat/show.html.erb").read
    assert_no_match(/\sstyle=/, view)
    assert_no_match(/\son[a-z]+=/, view)
    assert_no_match(/<script/, view)
  end

  test "Basecoat is vendored at its recorded version with its license" do
    assert_match(/basecoat-css 1\.3\.0 \(MIT/, Rails.root.join("vendor/basecoat/VERSION").read)
    assert_match(/MIT License/, Rails.root.join("vendor/basecoat/LICENSE.md").read)
    assert Rails.root.join("vendor/javascript/basecoat.js").exist?
  end
end
