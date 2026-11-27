require "test_helper"

# Rule 4, 7 and 17 of the design fundamentals (.claude/skills/verify/ui-brief.md): radius, spacing and font-size come
# from the scales in tokens.css, never from a raw number. This reads the stylesheets as text, so it needs no browser.
# New one-offs fail here. The DOM check (test/support/design_audit.js) owns geometry: concentric corners, even insets, targets.
#
# ALLOWED lists what existed when the test was written and could not be fixed yet, keyed by file, property and value (not
# line numbers, so edits do not invalidate it). Fix an entry and delete it: a stale entry fails too, so the list only shrinks.
class DesignLiteralsTest < ActiveSupport::TestCase
  STYLESHEETS = Rails.root.join("app/assets/stylesheets")
  PROPERTIES = /\A(?:border(?:-(?:top|bottom)-(?:left|right))?-radius|font-size|padding(?:-(?:top|right|bottom|left|inline|block)(?:-(?:start|end))?)?|margin(?:-(?:top|right|bottom|left|inline|block)(?:-(?:start|end))?)?|gap|row-gap|column-gap)\z/

  # Files whose owner is working on them right now; they are held to the lint once that work lands.
  # (onboarding.css and onboarding_world.css belong to the onboarding agent on this branch family.)
  EXEMPT_FILES = %w[tokens.css onboarding.css onboarding_world.css].freeze

  # Custom properties that scale painted art (the landing world is a drawing scaled to the window, not a layout on the scales).
  ART_UNITS = /var\(--(?:u|W|art|aw|badge|stage-w|scene-w|sz)\b/

  ALLOWED = {
    "admin.css" => [
      "font-size: clamp(1.75rem, 1.2rem + 2.4vw, 2.5rem)",
      "margin: 1.5rem 0 0.5rem",
      "font-size: 1.125rem"
    ],
    "application.css" => [
      "font-size: clamp(2rem, 1.2rem + 3.6vw, 3rem)",
      "font-size: 0.9em",
      "margin: -1px",
      "column-gap: 0.3em"
    ],
    "bosses.css" => [
      "font-size: clamp(2rem, 1.2rem + 3.6vw, var(--text-3xl))"
    ],
    "components.css" => [
      "gap: 0.5em",
      "padding: 0.5em 0.85em",
      "font-size: 0.85em",
      "margin-top: 0.1rem",
      "gap: 0.4em",
      "padding: 0.3em 1em 0.4em",
      "margin-top: clamp(2rem, 6vw, 5rem)",
      "gap: 0.35em"
    ],
    "dashboard.css" => [
      "padding: 0.1rem var(--space-3)",
      "padding-block: var(--space-2) 4.25rem",
      "margin-top: -2.5rem",
      "margin-top: -4.5rem",
      "margin-inline-start: -0.125rem"
    ],
    "landing.css" => [
      "border-radius: 0.58em",
      "gap: 0.36em",
      "padding: 0.5em 0.75em calc(0.56em + var(--press))",
      "font-size: clamp(1.25rem, 6.2vw, 1.625rem)",
      "padding: 0.04em 0.4em 0.1em",
      "border-radius: 999px",
      "margin-top: -1.5rem",
      "gap: 1rem",
      "padding: 1.25rem var(--side) 0",
      "padding-left: 0.5rem",
      "margin-bottom: -1px",
      "padding-block: 4rem var(--swoosh-overlap)",
      "gap: 1.25rem",
      "font-size: 2rem",
      "margin-top: 3.4rem",
      "font-size: 0.95rem",
      "margin-top: 3.25rem",
      "font-size: 1.1rem",
      "padding: 0 0.5rem calc(var(--edge-a) * 0.72 + 1.5vw)",
      "margin-top: -2.25rem",
      "margin-top: -10.5rem",
      "padding: clamp(2.5rem, 5vw, 4.5rem) 0 calc(var(--next, 0px) + clamp(3rem, 6vw, 5rem))",
      "margin-top: 1.25rem",
      "padding: 0.3em 1.4em",
      "margin-top: clamp(2.5rem, 5vw, 3.5rem)",
      "margin-top: 0.6rem",
      "padding-inline: 0.25rem",
      "margin-top: 0.15rem",
      "font-size: 0.875rem",
      "padding-bottom: calc(var(--next, 0px) * 0.55 + 2.5rem)",
      "padding-inline: min(var(--side), max(1rem, calc(100% - var(--wu) * 1050) / 2)))",
      "font-size: 1.375rem",
      "font-size: 0.9375rem",
      "font-size: clamp(2.5rem, 5.4vw, 4.25rem)",
      "gap: 0.9rem",
      "border-radius: 0.7rem",
      "padding: 0 1.15rem 0.42rem",
      "border-radius: 0.9rem 0.6rem 0.8rem 0.65rem",
      "border-radius: 0.6rem 0.95rem 0.65rem 0.85rem",
      "border-radius: 1.05rem",
      "padding: 0.85rem 0 0.9rem",
      "font-size: 1.1em",
      "border-radius: 0.4rem",
      "margin-top: -0.25rem",
      "padding-bottom: 1rem",
      "font-size: 1rem",
      "gap: 0.5rem",
      "padding: 0 0 1rem 1.25rem",
      "font-size: clamp(2.75rem, 6vw, 4.75rem)",
      "margin-top: clamp(1.5rem, 3vw, 2.25rem)",
      "font-size: clamp(1.5rem, 2.4vw, 1.75rem)",
      "margin-top: 1rem",
      "padding-bottom: clamp(5rem, 9vw, 8rem)"
    ],
    "landing_world_cave.css" => [
      "font-size: 0.65rem"
    ],
    "landing_world_cliff.css" => [
      "padding: 0.5rem 0.6rem 0.7rem",
      "border-radius: 0.5rem",
      "font-size: 1.375rem",
      "margin: 0.15rem 0 0",
      "font-size: 0.75rem",
      "padding-bottom: 0.6rem",
      "font-size: 1.25rem",
      "font-size: 0.6875rem"
    ],
    "landing_world_floor.css" => [
      "padding-top: calc(clamp(2.5rem, 5vw, 4.5rem) + var(--wu) * 50)",
      "padding-bottom: calc(var(--next, 0px) + clamp(3rem, 6vw, 5rem) + var(--wu) * 30)",
      "padding-bottom: calc(var(--next, 0px) + clamp(3rem, 6vw, 5rem) + var(--wu) * 70)"
    ],
    "landing_world_sand.css" => [
      "margin-bottom: 1.5rem",
      "padding-bottom: calc(var(--wu) * 230 + 2.5rem)",
      "padding-bottom: calc(var(--wu) * 230 + 3rem)",
      "padding-top: calc(clamp(2.5rem, 5vw, 4.5rem) + var(--wu) * 68)",
      "padding-bottom: calc(var(--wu) * 162 + 2.5rem)"
    ],
    "landing_world_sky.css" => [
      "margin-top: calc(-2.25rem - var(--wu) * 69)",
      "margin-top: calc(-10.5rem - var(--wu) * 15)"
    ],
    "notifications.css" => [
      "margin-top: 0.1rem"
    ],
    "shop.css" => [
      "margin-inline-start: -1.25em",
      "margin-inline-end: 0.2em"
    ],
    "styleguide.css" => [
      "padding: 0 0.3em",
      "font-size: 0.85em",
      "font-size: 0.75rem",
      "padding: 0.1em 0.6em",
      "font-size: clamp(3rem, 12vw, var(--text-sign-number))",
      "font-size: clamp(2.5rem, 9vw, var(--text-hero-title))",
      "font-size: clamp(2rem, 7vw, var(--text-sign-title))",
      "font-size: clamp(1.75rem, 6vw, var(--text-display))",
      "font-size: clamp(1.5rem, 5vw, var(--text-sign-body))"
    ]
  }.freeze

  def self.declarations(css)
    css = css.gsub(%r{/\*.*?\*/}m, "")
    css.scan(/([a-z-]+)\s*:\s*([^;{}]+)(?=;|})/).map { |prop, value| [ prop, value.strip.gsub(/\s+/, " ").sub(/\s*!important\z/, "") ] }
  end

  # true when the value is on the scale: only 0, keywords, percentages, viewport units alone, token vars, and calc/clamp/min/max of tokens.
  def self.literal?(value)
    return false if value.match?(ART_UNITS)

    stripped = value.gsub(/var\(--[a-z0-9-]+\)/, "T")
    stripped.scan(/(?<![\w.-])-?\d*\.?\d+(?:rem|em|px|pt)\b/).any? { |n| n.to_f != 0 }
  end

  def self.offenders
    Dir[STYLESHEETS.join("*.css")].sort.flat_map do |path|
      name = File.basename(path)
      next [] if EXEMPT_FILES.include?(name)

      declarations(File.read(path)).filter_map do |prop, value|
        "#{prop}: #{value}" if prop.match?(PROPERTIES) && literal?(value)
      end.uniq.map { |entry| [ name, entry ] }
    end
  end

  test "no new raw radius, spacing or font-size values outside tokens.css" do
    found = self.class.offenders.map { |file, entry| "#{file} | #{entry}" }
    allowed = ALLOWED.flat_map { |file, entries| entries.map { |entry| "#{file} | #{entry}" } }
    assert_empty found - allowed, "Use a token (--radius-*, --space-*, --text-*) or the concentric pattern; see ui-brief.md, Design fundamentals. New raw values:"
  end

  test "the allowlist has no stale entries" do
    found = self.class.offenders.map { |file, entry| "#{file} | #{entry}" }
    allowed = ALLOWED.flat_map { |file, entries| entries.map { |entry| "#{file} | #{entry}" } }
    assert_empty allowed - found, "These allowlist entries are fixed (or gone); delete them:"
  end

  test "tokens.css has the scales and the concentric floor" do
    tokens = File.read(STYLESHEETS.join("tokens.css"))
    %w[--radius-sm --radius-md --radius-lg --radius-xl --radius-full --radius-inner-min --space-1 --space-2 --space-4 --space-8 --text-sm --text-base].each do |name|
      assert_match(/#{Regexp.escape(name)}:/, tokens)
    end
  end
end
