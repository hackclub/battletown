# WCAG 2.x contrast ratios for the token pairs the app really uses (projects/battletown/specs/contract.md, "Design system" lists the results).
# `need` is 4.5 for text, 3.0 for large text (24px+ display type) and for non-text parts (borders, focus rings, fills).
module DesignSystem
  module Contrast
    Pair = Struct.new(:label, :fg, :bg, :need, :note, keyword_init: true)

    TEXT = 4.5
    LARGE = 3.0

    PAIRS = [
      Pair.new(label: "Text on cream", fg: "--color-text", bg: "--color-bg", need: TEXT),
      Pair.new(label: "Text on white", fg: "--color-text", bg: "--color-surface", need: TEXT),
      Pair.new(label: "Text on sky page", fg: "--color-text", bg: "--color-page", need: TEXT),
      Pair.new(label: "Muted text on sky page", fg: "--color-text-muted", bg: "--color-page", need: TEXT),
      Pair.new(label: "Muted text on cream", fg: "--color-text-muted", bg: "--color-bg", need: TEXT),
      Pair.new(label: "Muted text on white", fg: "--color-text-muted", bg: "--color-surface", need: TEXT),
      Pair.new(label: "Muted text on raised cream", fg: "--color-text-muted", bg: "--color-surface-raised", need: TEXT),
      Pair.new(label: "Link on sky page", fg: "--color-link", bg: "--color-page", need: TEXT),
      Pair.new(label: "Link on cream", fg: "--color-link", bg: "--color-bg", need: TEXT),
      Pair.new(label: "Link on white", fg: "--color-link", bg: "--color-surface", need: TEXT),
      Pair.new(label: "Link hover on sky page", fg: "--color-link-hover", bg: "--color-page", need: TEXT),
      Pair.new(label: "Ink blue on sky page", fg: "--color-ink-blue", bg: "--color-page", need: TEXT),
      Pair.new(label: "Ink blue on cream (secondary button, nav)", fg: "--color-ink-blue", bg: "--color-bg", need: TEXT),
      Pair.new(label: "Cream on ink blue (current nav link, footer)", fg: "--color-bg", bg: "--color-ink-blue", need: TEXT),
      Pair.new(label: "Cream on primary pink (the owner's choice)", fg: "--color-primary-contrast", bg: "--color-primary", need: LARGE, note: "accepted at 3.14:1"),
      Pair.new(label: "Cream on danger (button)", fg: "--color-primary-contrast", bg: "--color-danger", need: TEXT),
      Pair.new(label: "Cream on pink edge", fg: "--color-primary-contrast", bg: "--color-pink-edge", need: TEXT),
      Pair.new(label: "Text on cool ground (onboarding)", fg: "--color-text", bg: "--color-cool-ground", need: TEXT),
      Pair.new(label: "Muted text on cool ground", fg: "--color-text-muted", bg: "--color-cool-ground", need: TEXT),
      Pair.new(label: "Muted text on cool tint (onboarding cards)", fg: "--color-text-muted", bg: "--color-cool-tint", need: TEXT),
      Pair.new(label: "Text on cool tint", fg: "--color-text", bg: "--color-cool-tint", need: TEXT),
      Pair.new(label: "Blue edge on cool ground (links, Sign in)", fg: "--color-blue-edge", bg: "--color-cool-ground", need: TEXT),
      Pair.new(label: "Blue on cool ground (progress fill, focus ring)", fg: "--color-blue", bg: "--color-cool-ground", need: LARGE),
      Pair.new(label: "White on blue (Continue, selected card)", fg: "--color-surface", bg: "--color-blue", need: TEXT),
      Pair.new(label: "White on blue edge", fg: "--color-surface", bg: "--color-blue-edge", need: TEXT),
      Pair.new(label: "Ink blue on logo sky", fg: "--color-ink-blue", bg: "--color-logo-sky", need: TEXT),
      Pair.new(label: "Card face (white) against the cool ground", fg: "--color-cool-tint", bg: "--color-cool-ground", need: 1.25),
      Pair.new(label: "Card edge against the cool ground", fg: "--color-cool-tint-edge", bg: "--color-cool-ground", need: 1.25),
      Pair.new(label: "Selected card (blue) against the cool ground", fg: "--color-blue", bg: "--color-cool-ground", need: 3.0),
      Pair.new(label: "Blue ring on a white card", fg: "--color-blue", bg: "--color-cool-tint", need: 3.0),
      Pair.new(label: "Muted text on the cool ground edge", fg: "--color-text-muted", bg: "--color-cool-tint-edge", need: 3.0),
      Pair.new(label: "Hovered card face against the cool ground", fg: "--color-cool-hover", bg: "--color-cool-ground", need: 1.12),
      Pair.new(label: "Text on a hovered card", fg: "--color-text", bg: "--color-cool-hover", need: TEXT),
      Pair.new(label: "Muted text on a hovered card", fg: "--color-text-muted", bg: "--color-cool-hover", need: TEXT),
      Pair.new(label: "Progress fill on its track", fg: "--color-blue", bg: "--color-cool-tint", need: LARGE),
      Pair.new(label: "Cream on map blue", fg: "--color-bg", bg: "--color-map", need: TEXT),
      Pair.new(label: "Ink blue on sign yellow", fg: "--color-ink-blue", bg: "--color-sign-yellow", need: TEXT),
      Pair.new(label: "Cream on sign blue", fg: "--color-primary-contrast", bg: "--color-sign-blue", need: TEXT),
      Pair.new(label: "Cream on sign pink", fg: "--color-primary-contrast", bg: "--color-sign-pink", need: LARGE, note: "accepted at 3.14:1"),
      Pair.new(label: "White on sign green (the Fight together board)", fg: "--color-surface", bg: "--color-sign-green", need: TEXT),
      Pair.new(label: "White on sign green edge", fg: "--color-surface", bg: "--color-sign-green-edge", need: TEXT),
      Pair.new(label: "Cream on boss health empty", fg: "--color-primary-contrast", bg: "--color-hp-empty", need: TEXT),
      Pair.new(label: "Boss health fill vs empty (non-text)", fg: "--color-hp-fill", bg: "--color-hp-empty", need: LARGE, note: "non-text"),
      Pair.new(label: "Card title on chunky card", fg: "--color-card-title", bg: "--color-card-blue", need: TEXT),
      Pair.new(label: "Card title on lighter card blue", fg: "--color-card-title", bg: "--color-card-blue-light", need: TEXT),
      Pair.new(label: "Success ink on success tint", fg: "--color-success-ink", bg: "--color-success-bg", need: TEXT),
      Pair.new(label: "Danger ink on danger tint", fg: "--color-danger-ink", bg: "--color-danger-bg", need: TEXT),
      Pair.new(label: "Warning ink on warning tint", fg: "--color-warning-ink", bg: "--color-warning-bg", need: TEXT),
      Pair.new(label: "Info ink on info tint (cream)", fg: "--color-info-ink", bg: "--color-info-bg", need: TEXT),
      Pair.new(label: "Badge ink on raised cream", fg: "--color-ink-brown", bg: "--color-surface-raised", need: TEXT),
      Pair.new(label: "Field border on white (non-text)", fg: "--color-field-border", bg: "--color-surface", need: LARGE, note: "non-text"),
      Pair.new(label: "Focus ring on sky page (non-text)", fg: "--color-focus", bg: "--color-page", need: LARGE, note: "non-text"),
      Pair.new(label: "Focus ring on cream (non-text)", fg: "--color-focus", bg: "--color-bg", need: LARGE, note: "non-text"),
      Pair.new(label: "Cream focus ring on map blue (non-text)", fg: "--color-bg", bg: "--color-map", need: LARGE, note: "non-text"),
      Pair.new(label: "Dev tint: ink on tint", fg: "--color-dev-ink", bg: "--color-dev-bg", need: TEXT),
      Pair.new(label: "Admin tint: ink on tint", fg: "--color-admin-ink", bg: "--color-admin-bg", need: TEXT)
    ].freeze

    module_function

    def hex_of(value)
      hex = value.start_with?("--") ? Tokens.resolve(value) : value
      raise ArgumentError, "not a hex colour: #{value}" unless Tokens.hex?(hex)

      hex
    end

    def luminance(hex)
      red, green, blue = hex.delete("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }.map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
      0.2126 * red + 0.7152 * green + 0.0722 * blue
    end

    def ratio(fg, bg)
      light, dark = [ luminance(hex_of(fg)), luminance(hex_of(bg)) ].sort.reverse
      ((light + 0.05) / (dark + 0.05)).round(2)
    end

    # [pair, ratio, passes?] for every row.
    def results
      PAIRS.map do |pair|
        value = ratio(pair.fg, pair.bg)
        [ pair, value, value >= pair.need ]
      end
    end
  end
end
