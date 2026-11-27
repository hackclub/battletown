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
      "font-size: clamp(var(--text-xl), 1.2rem + 2.4vw, var(--text-2xl))",
      "font-size: 1.125rem"
    ],
    "application.css" => [
      "font-size: clamp(2rem, 1.2rem + 3.6vw, var(--text-display))",
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
      "margin-top: clamp(var(--space-8), 6vw, 5rem)",
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
      "padding: 0.5em 0.75em calc(0.56em - var(--cta-edge))",
      "font-size: clamp(var(--text-lg), 6.2vw, 1.625rem)",
      "padding: 0.04em 0.4em 0.1em",
      "padding: 1.25rem var(--side) 0",
      "margin-bottom: -1px",
      "gap: 1.25rem",
      "font-size: 2rem",
      "margin-top: 3.4rem",
      "font-size: 0.95rem",
      "margin-top: 3.25rem",
      "font-size: 1.1rem",
      "margin-top: -2.25rem",
      "margin-top: -10.5rem",
      "padding: clamp(2.5rem, 5vw, 4.5rem) 0 calc(var(--next, 0px) + clamp(var(--space-12), 6vw, 5rem))",
      "margin-top: 1.25rem",
      "padding: 0.3em 1.4em",
      "margin-top: clamp(2.5rem, 5vw, 3.5rem)",
      "margin-top: 0.6rem",
      "margin-top: 0.15rem",
      "padding-bottom: calc(var(--next, 0px) * 0.55 + 2.5rem)",
      "font-size: 1.375rem",
      "font-size: 0.9375rem",
      "font-size: clamp(var(--text-2xl), 5.4vw, 4.25rem)",
      "gap: 0.9rem",
      "border-radius: 0.7rem",
      "padding: 0 1.15rem 0.42rem",
      "border-radius: 0.9rem 0.6rem 0.8rem 0.65rem",
      "border-radius: 0.6rem 0.95rem 0.65rem 0.85rem",
      "border-radius: 1.05rem",
      "padding: 0.85rem 0 0.9rem",
      "font-size: 1.1em",
      "border-radius: 0.4rem",
      "padding: 0 0 var(--space-4) 1.25rem",
      "font-size: clamp(2.75rem, 6vw, 4.75rem)",
      "margin-top: clamp(var(--space-6), 3vw, 2.25rem)",
      "padding-bottom: clamp(5rem, 9vw, var(--space-32))"
    ],
    "landing_world_cave.css" => [
      "font-size: 0.65rem"
    ],
    "landing_world_cliff.css" => [
      "padding: var(--space-2) 0.6rem 0.7rem",
      "border-radius: 0.5rem",
      "font-size: 1.375rem",
      "margin: 0.15rem 0 0",
      "padding-bottom: 0.6rem",
      "font-size: 0.6875rem"
    ],
    "landing_world_floor.css" => [
      "padding-top: calc(clamp(2.5rem, 5vw, 4.5rem) + var(--wu) * 50)",
      "padding-bottom: calc(var(--next, 0px) + clamp(var(--space-12), 6vw, 5rem) + var(--wu) * 30)",
      "padding-bottom: calc(var(--next, 0px) + clamp(var(--space-12), 6vw, 5rem) + var(--wu) * 70)"
    ],
    "landing_world_sand.css" => [
      "padding-bottom: calc(var(--wu) * 230 + 2.5rem)",
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
      "padding: 0.1em 0.6em",
      "font-size: clamp(2rem, 7vw, var(--text-sign-title))"
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

  # --- Hard shadows only (Armand, 2026-11-27: "battletown always has hard shadows") ---------------------------------------
  # A shadow has zero blur and a solid color. Checked on every stylesheet, tokens.css included. Rings (0 0 0 Npx) are a
  # separate taste question and are not blur; the audit lists them.
  # onboarding_world.css belongs to the onboarding agent, who is moving it to the light theme; the logo drop shadows go there.
  BLUR_ALLOWED = [
    "onboarding_world.css | filter: drop-shadow(0 2px 5px rgb(16 40 90 / 0.3))",
    "onboarding_world.css | filter: drop-shadow(0 4px 10px rgb(16 40 90 / 0.3))",
    "onboarding_world.css | filter: drop-shadow(0 1px 3px rgb(16 40 90 / 0.3))"
  ].freeze

  def self.blurred_shadows
    Dir[STYLESHEETS.join("*.css")].sort.flat_map do |path|
      declarations(File.read(path)).flat_map do |prop, value|
        next [] unless prop.match?(/\A(?:box-shadow|text-shadow|--shadow-[a-z-]+)\z/) || (prop == "filter" && value.include?("drop-shadow"))

        layers = prop == "filter" ? value.scan(/drop-shadow\((.*?)\)(?=\s|\z)/).flatten : split_top_level(value, ",")
        layers.filter_map do |layer|
          parts = split_top_level(layer.strip, " ").reject { |part| part == "inset" }
          blur = parts[2]
          "#{File.basename(path)} | #{prop}: #{value}" if blur && blur.match?(/\A-?(?:\d*\.\d+|[1-9]\d*)(?:rem|em|px)?\z/) && blur.to_f != 0
        end
      end.uniq
    end
  end

  def self.split_top_level(text, separator)
    depth = 0
    pieces = [ +"" ]
    text.each_char do |char|
      depth += 1 if char == "("
      depth -= 1 if char == ")"
      if depth.zero? && char == separator
        pieces << +"" unless pieces.last.empty?
        next
      else
        pieces.last << char
      end
    end
    pieces.map(&:strip).reject(&:empty?)
  end

  test "every shadow is hard: zero blur" do
    assert_empty self.class.blurred_shadows - BLUR_ALLOWED, "Shadows are hard (zero blur, solid color; a darker shade of the thing's own color or --color-navy-edge):"
  end

  test "the blur allowlist has no stale entries" do
    assert_empty BLUR_ALLOWED - self.class.blurred_shadows
  end

  # --- Declarations the browser would drop -------------------------------------------------------------------------------
  # A stray bracket makes the browser throw the whole declaration away (landing.css once lost its side inset to one extra
  # ")"). This checks, per stylesheet, that braces balance and that every declaration value has balanced (), [] and quotes.
  # It does not check that property names or values are valid (the asset build and the browser do that: see audit.py
  # --css, which runs CSS.supports on each declaration in a real browser).
  def self.unbalanced
    Dir[STYLESHEETS.join("*.css")].sort.flat_map do |path|
      css = File.read(path).gsub(%r{/\*.*?\*/}m, "")
      problems = []
      problems << "braces do not balance (#{css.count('{')} open, #{css.count('}')} close)" if css.count("{") != css.count("}")
      css.scan(/([a-z-]+)\s*:\s*([^;{}]+)(?=;|})/).each do |prop, value|
        problems << "#{prop}: #{value.strip} (parentheses)" if value.count("(") != value.count(")")
        problems << "#{prop}: #{value.strip} (brackets)" if value.count("[") != value.count("]")
        problems << "#{prop}: #{value.strip} (quotes)" if value.count('"').odd? || value.count("'").odd?
      end
      problems.map { |problem| "#{File.basename(path)} | #{problem}" }
    end
  end

  test "no stylesheet has unbalanced brackets, parentheses or quotes in a declaration" do
    assert_empty self.class.unbalanced
  end

  test "the design fundamentals and the lint agree on what counts as a shadow" do
    assert_equal [ "0", "0", "0" ], self.class.split_top_level("0 0 0 red", " ").first(3)
    assert_equal [ "0 2px 0 red", "inset 0 -1px 0 blue" ], self.class.split_top_level("0 2px 0 red, inset 0 -1px 0 blue", ",")
    assert_equal 1, self.class.split_top_level("calc(1px + 2px) 0 0 red", " ").index("0")
  end

  test "tokens.css has the scales and the concentric floor" do
    tokens = File.read(STYLESHEETS.join("tokens.css"))
    %w[--radius-sm --radius-md --radius-lg --radius-xl --radius-full --radius-inner-min --space-1 --space-2 --space-4 --space-8 --text-sm --text-base].each do |name|
      assert_match(/#{Regexp.escape(name)}:/, tokens)
    end
  end
end
