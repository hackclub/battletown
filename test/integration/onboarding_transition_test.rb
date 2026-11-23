require "test_helper"
require "open3"

# The full-screen transition over onboarding steps (app/views/onboardings/_transition.html.erb): plain words that read well
# without the pictures, timing that is long enough to read, a backing panel for the text, room on short screens, and a
# skip that never gets in the way of the keyboard. What a browser has to draw (contrast, clipping) is pinned through the
# CSS source, with the measured numbers in the comments there.
class OnboardingTransitionTest < ActionDispatch::IntegrationTest
  CSS = Rails.root.join("app/assets/stylesheets/onboarding.css").read
  BLOCK = CSS[/Transition screens:.*?prefers-reduced-motion: reduce\) \{.*?^\}/m]
  CONTROLLER = Rails.root.join("app/javascript/controllers/onboarding_transition_controller.js")

  def step(name, params = {})
    patch onboarding_step_path(name), params: { user: params }
  end

  test "the welcome splash says its message in words, with no arrows, and keeps the skip hint" do
    get onboarding_step_path("age")
    assert_select ".transition--welcome[aria-hidden=true][data-turbo-temporary]"
    assert_select ".transition--welcome .transition__kicker", "Welcome to"
    assert_select ".transition--welcome .transition__title", "Make projects, take down the boss, get gear"
    assert_select ".transition--welcome .transition__hint", "Click anywhere to skip"
    assert_no_match(/→|—|–/, document_root_element.at_css(".transition--welcome").text)
    assert_select ".transition--welcome .transition__badge", 0
  end

  test "the words all sit inside the body panel that backs them" do
    get onboarding_step_path("age")
    assert_select ".transition > .transition__body > .transition__kicker"
    assert_select ".transition > .transition__body > .transition__title"
    assert_select ".transition > .transition__body > .transition__hint"
  end

  test "the others-like-you transition keeps its sentence, its hint and a badge that is only decoration" do
    get onboarding_step_path("age")
    step("age", age_group: "teen")
    step("prize", prize_key: "tshirt")
    follow_redirect!
    assert_select ".transition--proof[aria-hidden=true] .transition__body > .transition__title"
    assert_select ".transition--proof .transition__body > .transition__sub"
    assert_select ".transition--proof .transition__body > .transition__hint", "Click anywhere to skip"
    assert_select ".transition--proof .transition__badge img[alt=''], .transition--proof .transition__badge-emoji"
    assert_select "p.onboarding-note", /Battletown T-shirt/ # the frame mirrors it for screen readers
  end

  test "the panel behind the words is nearly solid white with rounded corners and a lift" do
    rule = css_rule(".transition__body")
    alpha = rule[/background:\s*rgb\(255 255 255 \/ ([0-9.]+)\)/, 1]
    assert alpha, "the panel needs a white background"
    assert_operator alpha.to_f, :>=, 0.85
    assert_match(/border-radius:\s*var\(--radius-lg\)/, rule)
    assert_match(/box-shadow:/, rule)
    assert_no_match(/text-shadow/, BLOCK) # no glow standing in for a backing
  end

  test "the worst-case contrast of the text colours on that panel passes AA" do
    # A black pixel of the artwork at 0.7 opacity over the sky is the darkest it can get; then the white panel goes on top.
    lin = ->(c) { (c /= 255.0) <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    lum = ->(rgb) { 0.2126 * lin.(rgb[0]) + 0.7152 * lin.(rgb[1]) + 0.0722 * lin.(rgb[2]) }
    ratio = ->(a, b) { hi, lo = [ lum.(a), lum.(b) ].sort.reverse; (hi + 0.05) / (lo + 0.05) }
    sky = [ 0xb1, 0xdc, 0xfe ]
    alpha = css_rule(".transition__body")[/rgb\(255 255 255 \/ ([0-9.]+)\)/, 1].to_f
    panel = sky.map { |c| alpha * 255 + (1 - alpha) * 0.3 * c }
    tokens = Rails.root.join("app/assets/stylesheets/tokens.css").read
    assert_includes tokens, "--color-ink-blue: #0044b2"
    assert_includes tokens, "--color-muted-on-light: #4a4234"
    assert_operator ratio.([ 0x00, 0x44, 0xb2 ], panel), :>=, 4.5
    assert_operator ratio.([ 0x4a, 0x42, 0x34 ], panel), :>=, 4.5
  end

  test "short screens: sizes come from the viewport height and the panel scrolls as a last resort" do
    body = css_rule(".transition__body")
    assert_match(/max-height:\s*calc\(100svh/, body)
    assert_match(/overflow:\s*auto/, body)
    assert_match(/svh/, CSS[/^\.transition__logo \{[^\n]*/])
    assert_match(/svh/, CSS[/^\.transition--proof \.transition__badge \{[^\n]*/])
    short = CSS[/@media \(max-height: 22rem\) \{(.*?)^\}/m, 1]
    assert_match(/\.transition__badge \{ display: none; \}/, short) # only the decorative badge is dropped
    assert_no_match(/transition__(title|sub|kicker|hint)[^{]*\{[^}]*display:\s*none/, BLOCK) # never the words
  end

  test "the transitions last long enough to read and the step underneath rises in as they end" do
    assert_match(/\.onboarding-page \{ --len: 4\.5s; \}/, BLOCK)
    assert_match(/\.onboarding-page:has\(\.transition--proof\) \{ --len: 4s; \}/, BLOCK)
    assert_match(/\.transition-enter \{ animation: transition-content-in 0\.6s ease calc\(var\(--len\) - 0\.5s\) backwards; \}/, BLOCK)
    assert_match(/animation: transition-out var\(--len\) ease forwards/, BLOCK)
    fade = BLOCK[/@keyframes transition-out \{(.*?)^\}/m, 1]
    assert_match(/88% \{ opacity: 1; visibility: visible; \}/, fade)
    assert_match(/100% \{ opacity: 0; visibility: hidden; \}/, fade)
  end

  test "nothing repeats or flashes: no animation in the transition loops" do
    assert_no_match(/infinite|animation-iteration-count/, BLOCK)
  end

  test "reduced motion removes the overlay and the wait" do
    reduced = BLOCK[/@media \(prefers-reduced-motion: reduce\) \{(.*?)^\}/m, 1]
    assert_match(/\.transition \{ display: none; \}/, reduced)
    assert_match(/\.transition-enter \{ animation: none; \}/, reduced)
  end

  test "the controller parses, and leaves Tab, Enter, Space, arrows and browser shortcuts alone" do
    node, status = Open3.capture2e("which", "node")
    skip "node is not installed" unless status.success?
    out, status = Open3.capture2e(node.strip, "--check", CONTROLLER.to_s)
    assert status.success?, out

    source = CONTROLLER.read
    assert_match(/event\.ctrlKey \|\| event\.metaKey \|\| event\.altKey/, source) # Ctrl+C, Cmd+Tab and so on do not dismiss it
    assert_match(/"Shift", "Control", "Alt", "Meta"/, source)
    assert_no_match(/preventDefault|stopPropagation/, source) # nothing is swallowed, so keyboard use still works
  end

  private

  def css_rule(selector)
    BLOCK[/^#{Regexp.escape(selector)} \{(.*?)^\}/m, 1] or flunk "no #{selector} rule"
  end
end
