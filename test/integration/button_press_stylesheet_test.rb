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

  test "--press is the one animated length: registered, and the only thing a transition on a button touches" do
    tokens = File.read(Rails.root.join("app/assets/stylesheets/tokens.css"))
    assert_match(/@property --press\s*\{[^}]*syntax:\s*"<length>"/m, tokens)
    offenders = SHEETS.flat_map do |path|
      rules(File.read(path)).select { |selector, body| selector.match?(/\.(btn|cta__face|age-choice|chip|choice__body)\b/) && body.match?(/transition:/) }
        .reject { |_, body| body[/transition:\s*([^;]*)/, 1].strip.match?(/\A--press 120ms ease\z/) }
        .map { |selector, _| "#{File.basename(path)}: #{selector}" }
    end
    assert_empty offenders, "a button may transition only --press (margin, padding, height or box-shadow moving the base for a frame is the bug)"
  end

  test "the shared rule keeps the base fixed: the face translates and the edge shadow is drawn the same amount lower" do
    css = File.read(Rails.root.join("app/assets/stylesheets/components.css"))
    btn = rules(css).find { |selector, _| selector == ".btn" }&.last or flunk("no .btn rule")
    assert_match(/--btn-push:\s*round\(nearest, var\(--press\), 1px\)/, btn)
    assert_match(/translate:\s*0 calc\(-1 \* var\(--btn-push\)\)/, btn)
    assert_match(/box-shadow:\s*0 calc\(var\(--btn-edge-size\) \+ var\(--btn-push\)\) 0 var\(--btn-edge\)/, btn)
    assert_no_match(/margin-bottom:[^;]*press|min-height:[^;]*press|padding:[^;]*press/, btn)
    hit = rules(css).find { |selector, _| selector == ".btn::before" }&.last or flunk("no click-area rule")
    assert_match(/translate:\s*0 var\(--btn-push\)/, hit)
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

  test "the landing call to action never moves or repaints the link that holds the click area and the base" do
    css = File.read(Rails.root.join("app/assets/stylesheets/landing.css"))
    link = rules(css).find { |selector, _| selector == ".landing .cta" }&.last or flunk("no .cta rule")
    assert_match(/background: var\(--pink-shade\)/, link)
    assert_no_match(/translate|transition/, link)
    states = rules(css).select { |selector, _| selector.include?(".cta") && selector.match?(/:(hover|active)/) }
    assert_operator states.size, :>=, 2
    states.each { |selector, _| assert_match(/\.cta__face\z/, selector) }
    face = rules(css).find { |selector, _| selector == ".landing .cta__face" }&.last or flunk("no .cta__face rule")
    assert_match(/translate:\s*0 calc\(-1 \* round\(nearest, var\(--press\), 1px\)\)/, face)
  end
end
