require "test_helper"

class DesignSystemTokensTest < ActiveSupport::TestCase
  test "reads the tokens from tokens.css and follows var() references" do
    assert_equal "#b1dcfe", DesignSystem::Tokens.resolve("--color-page")
    assert_equal "#a60040", DesignSystem::Tokens.resolve("--color-link")
    assert_equal "#4a4234", DesignSystem::Tokens.resolve("--color-text-muted")
    assert_raises(ArgumentError) { DesignSystem::Tokens.resolve("--color-nope") }
  end

  test "every colour token resolves to a six digit hex" do
    DesignSystem::Tokens.colors.each { |token| assert DesignSystem::Tokens.hex?(token.value), "#{token.name} is #{token.value}" }
  end

  test "the names other stylesheets rely on still exist" do
    names = DesignSystem::Tokens.all.map(&:name)
    %w[--color-bg --color-surface --color-surface-raised --color-border --color-text --color-text-muted --color-primary
       --color-primary-contrast --color-secondary --color-success --color-danger --color-focus --color-cta --color-highlight
       --color-sky --color-sky-soft --color-ink-brown --color-cta-edge --color-dev --color-dev-bg --color-dev-border
       --color-dev-ink --color-admin --color-admin-bg --color-admin-border --color-admin-ink --font-body --font-display
       --font-mono --text-xs --text-sm --text-base --text-lg --text-xl --text-2xl --text-3xl --text-display
       --tracking-display --leading-tight --leading-body --space-1 --space-2 --space-3 --space-4 --space-6 --space-8
       --space-12 --space-16 --radius-sm --radius-md --radius-lg --radius-xl --radius-full --shadow-sm --shadow-md
       --shadow-button-edge --border-chunky --shadow-cta-edge --container-width].each do |name|
      assert_includes names, name
    end
  end

  test "every contrast pair the app uses meets its WCAG AA threshold" do
    failures = DesignSystem::Contrast.results.reject { |_pair, _ratio, ok| ok }
    assert_empty failures.map { |pair, ratio, _| "#{pair.label}: #{ratio} (needs #{pair.need})" }
  end

  test "the ratio maths matches the known black on white and the Figma pink values" do
    assert_equal 21.0, DesignSystem::Contrast.ratio("#000000", "#ffffff")
    assert_in_delta 3.18, DesignSystem::Contrast.ratio("#ffffff", "#ff4797"), 0.01
  end

  test "every colour token has a swatch rule in styleguide.css" do
    css = Rails.root.join("app/assets/stylesheets/styleguide.css").read
    missing = DesignSystem::Tokens.colors.map(&:name).reject { |name| css.include?(%(.sg-swatch[data-token="#{name}"])) }
    assert_empty missing
  end
end
