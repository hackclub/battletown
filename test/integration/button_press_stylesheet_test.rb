require "test_helper"

# Buttons are FLAT by default (Armand, 2026-11-27: the animated 3D button is for sparing use). The raised slab is the opt-in
# .slab-btn (the landing .cta and the onboarding hold-to-sign are both it): the element is the BASE and never moves or animates; only
# .slab-btn__face translates, from one registered length, --press.
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
      rules(File.read(path)).select { |sel, body| sel.match?(/\.slab-btn/) && body.match?(/transition:/) }
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

  test "the one raised button keeps its base fixed: the face translates from --press and nothing else moves" do
    link = rule(COMPONENTS, ".slab-btn")
    assert_match(/background:\s*var\(--slab-base\)/, link)
    assert_no_match(/translate|transform|transition|box-shadow|margin-bottom/, link)
    face = rule(COMPONENTS, ".slab-btn__face")
    assert_match(/translate:\s*0 calc\(-1 \* round\(nearest, var\(--press\), 1px\)\)/, face)
    assert_match(/background:\s*var\(--slab-face\)/, face)
    assert_no_match(/box-shadow|background-image|gradient/, face)
    states = rules(COMPONENTS).select { |sel, _| sel.match?(/\A\.slab-btn:(is\(:hover, :focus-visible\)|active) \.slab-btn__face\z/) }
    assert_equal 2, states.size
    states.each { |sel, body| assert_equal [ "--press" ], body.split(";").map { |d| d.split(":").first.strip }.reject(&:empty?), sel }
  end

  test "there is no second slab: .btn--raised and its rim are gone, and no stylesheet draws a lighter line under a raised base" do
    SHEETS.each do |path|
      css = File.read(path).gsub(%r{/\*.*?\*/}m, "")
      assert_no_match(/btn--raised|--btn-rim|cta__face|--cta-edge/, css, File.basename(path))
    end
  end

  test "the landing call to action is the shared slab, colored by variables, and never moves or repaints its link" do
    css = File.read(Rails.root.join("app/assets/stylesheets/landing.css"))
    link = rule(css, ".landing .cta")
    assert_match(/--slab-base:\s*var\(--pink-shade\)/, link)
    assert_no_match(/translate|transition|background:/, link)
    assert_match(/slab-btn/, File.read(Rails.root.join("app/views/landing/_cta.html.erb")))
    assert_match(/slab-btn__face/, File.read(Rails.root.join("app/views/landing/_cta_face.html.erb")))
  end

  test "a raised button's edge is computed from its own fill: no .btn rule sets an edge color by hand, and one fill property drives both" do
    assert_match(/--btn-edge:\s*color-mix\(in oklab, var\(--btn-bg\) \d+%, black\)/, rule(COMPONENTS, ".btn"))
    assert_match(/background:\s*var\(--btn-bg\)/, rule(COMPONENTS, ".btn"))
    hand_set = SHEETS.flat_map do |path|
      rules(File.read(path)).select { |sel, body| sel.match?(/\.btn\b|\.btn--/) && body.match?(/--btn-edge:/) }
        .reject { |sel, body| sel.match?(/\.btn--ghost\z/) && body[/--btn-edge:\s*([^;]*)/, 1].strip == "transparent" } # ghost has no edge
        .reject { |_, body| body[/--btn-edge:\s*([^;]*)/, 1].strip == "transparent" } # a disabled look with no edge at all
        .reject { |sel, _| sel == ".btn" } # the one derivation
        .map { |sel, _| "#{File.basename(path)}: #{sel}" }
    end
    assert_match(/--btn-border:\s*var\(--btn-bg\)/, rule(COMPONENTS, ".btn")) # the rim shadow under the edge is the fill too
    rims = rules(COMPONENTS).select { |sel, body| sel.match?(/\.btn--(primary|lg|cta|danger)/) && body.match?(/--btn-border:/) }.map(&:first)
    assert_empty rims, "a variant sets --btn-bg only: its border and rim follow the fill"
    assert_empty hand_set, "never set --btn-edge by hand (a pink edge under a blue face was this bug); set --btn-bg and the edge follows"
  end

  # The sign-up button on /onboarding/signup was a .btn--primary.btn--lg on a blue page. A rule that paints its face with
  # a literal `background:` leaves --btn-bg (and so the derived edge) pink: a blue face on a pink strip. Page rules must set --btn-bg.
  # onboarding_world.css (the onboarding agent's) still does at the line below; delete it from this list when that line becomes
  # `--btn-bg: var(--ob-primary);`.
  KNOWN_FACE_PAINTS = [].freeze

  test "no page rule paints a button face with a literal background that its edge would not follow" do
    paints = SHEETS.flat_map do |path|
      next [] if File.basename(path) == "components.css"
      rules(File.read(path)).select { |sel, body| sel.match?(/\.btn--primary\.btn--lg\z|\A\.btn--primary\.btn--lg\z/) && body.match?(/(?:\A|[;\s])background:/) }
        .map { |sel, _| "#{File.basename(path)}: #{sel}" }
    end
    assert_empty paints - KNOWN_FACE_PAINTS, "set --btn-bg instead of background: so the raised edge follows the face"
    assert_empty KNOWN_FACE_PAINTS - paints, "fixed: remove it from KNOWN_FACE_PAINTS"
  end

  test "raised is sparing: only the landing buttons and the hold-to-sign use the slab" do
    users = Dir[Rails.root.join("app/views/**/*.erb")].select { |f| File.read(f).match?(/slab-btn(?!__)/) }.map { |f| f.sub("#{Rails.root}/", "") }
    allowed = %w[app/views/dev/styleguide/show.html.erb app/views/onboardings/signup.html.erb app/views/landing/_cta.html.erb]
    assert_empty users - allowed
  end
end
