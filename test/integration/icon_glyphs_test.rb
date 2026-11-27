require "test_helper"

# Icons are drawn with IconHelper#icon (an inline SVG centered in its viewBox), never with a text character: a character's
# ink is not centered in its line box, so a "‹" or "✓" always sits a little off-center in its button, and no CSS fix holds
# across fonts and sizes (Armand, 2026-11-27: "icons should always be centered properly ... so i don't have to point it out").
#
# This test fails on a text glyph used as an icon in views, helpers, JavaScript or stylesheets. The measured check of
# the rendered result is test/system/icon_centering_test.rb. To add an icon, add it to IconHelper::ICONS.
class IconGlyphsTest < ActiveSupport::TestCase
  ROOT = Rails.root

  # Characters that are icons when they stand alone in a control: arrows, chevrons, ticks, crosses, triangles, burger.
  # (Ordinary punctuation, such as the ellipsis, the en dash and the middle dot, is text and is not on this list.)
  ICON_GLYPHS = %w[‹ › « » ← → ↑ ↓ ↩ ↪ ↗ ↘ × ✕ ✖ ✗ ✘ ☓ ✓ ✔ ☑ ✅ ▸ ▾ ▴ ▿ ▶ ◀ ▼ ▲ ◂ ⌄ ⌃ ☰ ≡ ⋯ ‖ − ＋ ✚].freeze
  ICON_ENTITIES = %w[&lsaquo; &rsaquo; &laquo; &raquo; &larr; &rarr; &uarr; &darr; &times; &check; &minus; &#10003; &#10005; &#9656; &#9662;].freeze
  # CSS escapes for the same characters, e.g. content: "\2713".
  ICON_CODEPOINTS = %w[2039 203a 00ab 00bb 2190 2192 2191 2193 21a9 00d7 2715 2716 2713 2714 25b8 25be 25b4 25b6 25c0 25bc 25b2 25c2 2212 2016 2630 2261].freeze

  # Known holes, each to be removed with its fix. A pattern is matched against "path:line: source line".
  ALLOWLIST = [
    # The onboarding branch deletes the back button ("‹") and is changing these stylesheets; their icons move to IconHelper
    # with that work (planner: "Center every icon" follow-up for the onboarding files).
    %r{\Aapp/views/onboardings/_frame\.html\.erb:},
    %r{\Aapp/assets/stylesheets/onboarding(_world)?\.css:}
  ].freeze

  test "no stylesheet draws an icon with a text character in content" do
    offences = scan(Dir[ROOT.join("app/assets/stylesheets/*.css")]) do |line|
      next unless (value = line[/content:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/, 1])

      text = value[1..-2]
      next if text.empty? || text.match?(/\A(\\00b7|\\00a0|\s)+\z/i) # an empty box, or just a space or a middle dot between words

      glyph?(text) || text.match?(/\A\\?[[:graph:]]\z/) # a one-character content is an icon in all but name ("+", "!", "x")
    end
    assert_empty offences, "Draw icons with IconHelper#icon (an SVG), not `content:` text. See app/helpers/icon_helper.rb.\n#{offences.join("\n")}"
  end

  test "no view, helper or script uses a text character as an icon" do
    files = Dir[ROOT.join("app/{views,helpers,javascript}/**/*.{erb,rb,js}")].reject { |path| path.end_with?("icon_helper.rb") }
    offences = scan(files) { |line| glyph?(line) || ICON_ENTITIES.any? { |entity| line.include?(entity) } }
    assert_empty offences, "Draw icons with IconHelper#icon (an SVG), not a text character. See app/helpers/icon_helper.rb.\n#{offences.join("\n")}"
  end

  private

  def glyph?(text)
    ICON_GLYPHS.any? { |glyph| text.include?(glyph) } || ICON_CODEPOINTS.any? { |code| text.match?(/\\0*#{code}\b/i) }
  end

  def scan(paths)
    paths.sort.flat_map do |path|
      relative = Pathname(path).relative_path_from(ROOT).to_s
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        entry = "#{relative}:#{index + 1}: #{line.strip}"
        entry if yield(line) && ALLOWLIST.none? { |pattern| pattern.match?(entry) }
      end
    end
  end
end
