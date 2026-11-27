require "test_helper"

# Buttons are FLAT by default (Armand, 2026-11-27: the animated 3D button is for sparing use). The raised slab is the opt-in
# .btn--raised (and the landing .cta): its BASE never moves and nothing about the base animates; only the face translates, from one
# registered length, --press, so the face and the edge shadow change in the same frame and cancel exactly.
class ButtonPressStylesheetTest < ActiveSupport::TestCase
  SHEETS = Dir[Rails.root.join("app/assets/stylesheets/*.css")].sort
  COMPONENTS = File.read(Rails.root.join("app/assets/stylesheets/components.css"))

  # [selector, body] of every plain rule block (the sheets nest only @media and @layer, never rules inside rules).
  def rules(css)
    css.gsub(%r{/\*.*?\*/}m, "").scan(/([^{}@;]+)\{([^{}]*)\}/m).map { |selector, body| [ selector.strip, body ] }
  end

  def rule(css, selector) = rules(css).find { |sel, _| sel == selector }&.last || flunk("no rule for #{selector}")

  test "the default .btn is flat: no edge shadow, no translate, no margin trick, and its states change only the fill step" do
    btn = rule(COMPONENTS, ".btn")
    assert_match(/box-shadow:\s*inset var\(--btn-step\)/, btn)
    assert_no_match(/translate|transform|margin-bottom|--btn-push|--press/, btn)
    flat_states = rules(COMPONENTS).select { |sel, _| sel.match?(/\A\.btn(--ghost)?:(hover|active):not/) }
    assert_operator flat_states.size, :>=, 4
    flat_states.each do |sel, body|
      assert_no_match(/translate|transform|margin|padding|min-height|border-width/, body, sel)
      assert_no_match(/blur|\d+px \d+px \d+px/, body, "#{sel}: shadows are hard (zero blur)")
    end
  end

  test "--press is registered, and it is the only thing a transition on a raised button touches" do
    tokens = File.read(Rails.root.join("app/assets/stylesheets/tokens.css"))
    assert_match(/@property --press\s*\{[^}]*syntax:\s*"<length>"/m, tokens)
    offenders = SHEETS.flat_map do |path|
      rules(File.read(path)).select { |sel, body| sel.match?(/\.(btn--raised|cta__face)\b/) && body.match?(/transition:/) }
        .reject { |_, body| body[/transition:\s*([^;]*)/, 1].strip == "--press 120ms ease" }
        .map { |sel, _| "#{File.basename(path)}: #{sel}" }
    end
    assert_empty offenders, "a raised button may transition only --press (margin, padding, height or box-shadow moving the base for a frame is the bug)"
  end

  test "no hover, press or focus rule translates or transforms a whole button except through --press" do
    offenders = SHEETS.flat_map do |path|
      rules(File.read(path)).select { |sel, body| sel.match?(/:(hover|active|focus-visible|focus)\b/) && body.match?(/(^|[;\s])(translate|transform|scale)\s*:/) }
        .map { |sel, _| "#{File.basename(path)}: #{sel}" }
    end - [ "application.css: .skip-link:focus-visible" ] # the skip link slides in from off screen: it is not a button
    assert_empty offenders
  end

  test "the raised variant keeps the base fixed: the face translates and the hard edge shadow is drawn the same amount lower" do
    raised = rule(COMPONENTS, ".btn--raised")
    assert_match(/--btn-push:\s*round\(nearest, var\(--press\), 1px\)/, raised)
    assert_match(/translate:\s*0 calc\(-1 \* var\(--btn-push\)\)/, raised)
    assert_match(/box-shadow:\s*0 calc\(var\(--btn-edge-size\) \+ var\(--btn-push\)\) 0 var\(--btn-edge\)/, raised)
    assert_no_match(/min-height:[^;]*press|padding[^;]*press/, raised)
    hit = rule(COMPONENTS, ".btn--raised::before")
    assert_match(/translate:\s*0 var\(--btn-push\)/, hit)
    states = rules(COMPONENTS).select { |sel, _| sel.start_with?(".btn--raised:is(:hover, :focus-visible)", ".btn--raised:active") }
    assert_equal 2, states.size
    states.each do |sel, body|
      assert_equal [ "--press" ], body.split(";").map { |d| d.split(":").first.strip }.reject(&:empty?), sel
      assert_match(/:not\(:disabled, \[aria-disabled="true"\]\)/, sel)
    end
  end

  test "the landing call to action never moves or repaints the link that holds the click area and the base" do
    css = File.read(Rails.root.join("app/assets/stylesheets/landing.css"))
    link = rule(css, ".landing .cta")
    assert_match(/background: var\(--pink-shade\)/, link)
    assert_no_match(/translate|transition/, link)
    states = rules(css).select { |sel, _| sel.include?(".cta") && sel.match?(/:(hover|active)/) }
    assert_operator states.size, :>=, 2
    states.each { |sel, _| assert_match(/\.cta__face\z/, sel) }
    assert_match(/translate:\s*0 calc\(-1 \* round\(nearest, var\(--press\), 1px\)\)/, rule(css, ".landing .cta__face"))
  end

  test "raised is sparing: only the landing buttons and the sign-in on the reveal use it" do
    users = Dir[Rails.root.join("app/views/**/*.erb")].select { |f| File.read(f).include?("btn--raised") }.map { |f| f.sub("#{Rails.root}/", "") }
    allowed = %w[app/views/dev/styleguide/show.html.erb app/views/onboardings/signup.html.erb app/views/onboardings/_frame.html.erb app/views/onboardings/celebrate.html.erb app/views/onboardings/account.html.erb]
    assert_empty users - allowed
  end
end
