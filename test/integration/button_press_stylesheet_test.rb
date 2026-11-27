require "test_helper"

# Raised buttons are slabs: a face on a darker edge. On hover the slab grows taller and when pressed it squashes, but its base
# (the bottom of the edge) never moves, so nothing around it shifts (Armand, 2026-11-27: "buttons sort of extend and squash like
# a cuboid ... the base should stay in the same position"). The state rules therefore change only --press; the one length is
# folded into padding, minimum height, bottom margin, translate and edge size by the element itself. A hover or press rule that
# sets translate or transform moves the whole button, base included, and fails here.
class ButtonPressStylesheetTest < ActiveSupport::TestCase
  SHEETS = Dir[Rails.root.join("app/assets/stylesheets/*.css")].sort

  # [selector, body] of every plain rule block (the sheets nest only @media and @layer, never rules inside rules).
  def rules(css)
    css.gsub(%r{/\*.*?\*/}m, "").scan(/([^{}@;]+)\{([^{}]*)\}/m).map { |selector, body| [ selector.strip, body ] }
  end

  test "no hover, press or focus rule moves a whole button" do
    offenders = SHEETS.flat_map do |path|
      rules(File.read(path)).select { |selector, body| selector.match?(/:(hover|active|focus-visible|focus)\b/) && body.match?(/(^|[;\s])(translate|transform)\s*:/) }
        .map { |selector, _| "#{File.basename(path)}: #{selector}" }
    end - [ "application.css: .skip-link:focus-visible" ] # the skip link slides in from off screen: it is not a raised button
    assert_empty offenders, "these state rules translate or transform the button, so its base would move: set --press instead (tokens.css)"
  end

  test "the shared rule keeps the base fixed: every --press term moves together" do
    css = File.read(Rails.root.join("app/assets/stylesheets/components.css"))
    btn = rules(css).find { |selector, _| selector == ".btn" }&.last or flunk("no .btn rule")
    assert_match(/translate:\s*0 calc\(-1 \* var\(--press\)\)/, btn)
    assert_match(/margin-bottom:\s*calc\(-1 \* var\(--press\)\)/, btn)
    assert_match(/min-height:\s*calc\(var\(--btn-min-h\) \+ var\(--press\)\)/, btn)
    assert_match(/padding:[^;]*calc\(var\(--btn-pb\) \+ var\(--press\)\)/, btn)
    assert_match(/box-shadow:\s*inset 0 calc\(-1 \* \(var\(--btn-edge-size\) \+ var\(--press\)\)\)/, btn)
  end

  test "hover, focus and press change --press and nothing else, and not on a disabled button" do
    css = File.read(Rails.root.join("app/assets/stylesheets/components.css"))
    states = rules(css).select { |selector, _| selector.start_with?(".btn:is(:hover, :focus-visible)", ".btn:active") }
    assert_equal 2, states.size
    states.each do |selector, body|
      assert_equal [ "--press" ], body.split(";").map { |d| d.split(":").first.strip }.reject(&:empty?), selector
      assert_match(/:not\(:disabled, \[aria-disabled="true"\]\)/, selector)
    end
  end

  test "the landing call to action moves its face, never the link that holds the click area" do
    css = File.read(Rails.root.join("app/assets/stylesheets/landing.css"))
    states = rules(css).select { |selector, _| selector.include?(".cta") && selector.match?(/:(hover|active)/) }
    assert_operator states.size, :>=, 2
    states.each { |selector, _| assert_match(/\.cta__face\z/, selector) }
    face = rules(css).find { |selector, _| selector == ".landing .cta__face" }&.last or flunk("no .cta__face rule")
    assert_match(/translate:\s*0 calc\(-1 \* var\(--press\)\)/, face)
    assert_match(/margin-bottom:\s*calc\(-1 \* var\(--press\)\)/, face)
  end
end
