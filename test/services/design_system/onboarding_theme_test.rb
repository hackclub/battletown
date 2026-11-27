require "test_helper"

# The onboarding sits on a light cool ground. Text there is navy; white or cream text is only for the blue fills (the primary button,
# a picked card). These checks keep a white-on-light rule from coming back (it did, three times, when the ground changed).
class DesignSystem::OnboardingThemeTest < ActiveSupport::TestCase
  LIGHT_TEXT = /(?<![-\w])color:\s*(var\(--color-bg\)|var\(--color-surface\)|var\(--ob-cream\)|var\(--color-cream\)|#fff\w*|white)/
  ON_BLUE = /btn--primary|:checked|aria-pressed|age-choice:hover|pace-choice/

  test "no onboarding rule sets white or cream text except on the blue fills" do
    css = Rails.root.join("app/assets/stylesheets/onboarding_world.css").read
    # ground-less pieces whose rules mention a light text colour: find the selector block of each offending declaration
    offenders = []
    css.scan(/([^{}]+)\{([^{}]*)\}/m) do |selector, body|
      next unless body.match?(LIGHT_TEXT)
      next if selector.match?(ON_BLUE) || body.match?(/background(-color)?:\s*var\(--(?:color-blue|ob-pink)\)/)
      offenders << selector.strip.lines.last.strip
    end
    assert_empty offenders, "light text on the light ground in: #{offenders.join(' | ')}"
  end

  test "the ground and its text pairs are registered in the contrast check" do
    labels = DesignSystem::Contrast::PAIRS.map(&:bg)
    assert_includes labels, "--color-cool-ground"
    assert_includes labels, "--color-cool-tint"
    DesignSystem::Contrast::PAIRS.select { |pair| %w[--color-cool-ground --color-cool-tint].include?(pair.bg) }.each do |pair|
      assert_operator DesignSystem::Contrast.ratio(pair.fg, pair.bg), :>=, pair.need, pair.label
    end
  end

  test "the splash text and the skip hint use navy tokens" do
    css = Rails.root.join("app/assets/stylesheets/onboarding_world.css").read
    assert_match(/\.transition__kicker, \.transition__title \{ color: var\(--color-ink-blue\)/, css)
    assert_match(/\.transition__hint \{ color: var\(--color-text-muted\)/, css)
  end
end
