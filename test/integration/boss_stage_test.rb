require "test_helper"
require_relative "../support/fighters_helper"
require_relative "../support/profiles_helper"

# The fighters drawn around the boss on the dashboard (app/views/dashboard/_stage.html.erb and _fighter.html.erb), as served.
class BossStageTest < ActionDispatch::IntegrationTest
  include FightersHelper
  include ProfilesHelper

  setup do
    @user = users(:onboarded)
    @today = Time.current.utc.to_date
    @user.update_columns(created_at: (@today - 30).in_time_zone("UTC"), signed_up_on: @today - 30)
    @boss = make_boss(starts_on: friday_on_or_before(@today), hp_seconds: 100 * HOUR)
  end

  teardown { reset_omniauth }

  # A person who coded in the last day (the real clock: the page counts back from now).
  def live(key, **args) = fighter(key, now: Time.current, **args)

  def stage
    sign_in_as @user
    get dashboard_path
    assert_response :success
  end

  test "at most 12 circles are drawn however many coded, and the counts are everybody's" do
    15.times { |index| live("many#{index}", seconds: 900 + (index * 60)) }
    live("shipper", seconds: 900).tap { |shipper| ship_damage(shipper, 3600, on: Time.current) }
    stage

    assert_select ".stage__crowd > li.stage__fan", 12
    assert_select ".stage__arena p.visually-hidden", /16 people coded in the last day\. 1 of them shipped\./
    assert_select "li.stage__fan--p1.stage__fan--hit-ship", 1, "the shipper is first"
    (1..12).each { |slot| assert_select "li.stage__fan--p#{slot}", 1 }
  end

  test "size classes come from the minutes, hit classes from what they did" do
    ada = live("ada", seconds: 2 * 3600, name: "Ada")
    ship_damage(ada, 3600, on: Time.current)
    live("steady", seconds: 3600, name: "Bo")
    live("warm", seconds: 1500)
    live("tiny", seconds: 900)
    live("huge", seconds: 5 * 3600)
    stage

    assert_select "li.stage__fan--s4.stage__fan--hit-ship", 1
    assert_select "li.stage__fan--s3.stage__fan--hit-code", 1
    assert_select "li.stage__fan--s1:not(.stage__fan--hit-ship):not(.stage__fan--hit-code)", 2, "under the daily goal: no hit"
    assert_select "li.stage__fan--s5.stage__fan--hit-code", 1
    assert_select "li.stage__fan--s1.stage__fan--hit-ship, li.stage__fan--s1.stage__fan--hit-code", 0
  end

  test "every player is a link to their profile, named by their chosen name or a generated handle" do
    ada = live("ada", seconds: 3600, name: "Ada")
    plain = live("plainone", seconds: 1800)
    stage

    assert_select ".stage__crowd a.stage__fighter", 2
    assert_select ".stage__crowd span.stage__fighter", 0, "nobody is an anonymous circle"
    assert_select ".stage__crowd a.stage__fighter.avatar[href=?]", player_path(ada.public_slug), text: "A"
    assert_select ".stage__crowd a.avatar--tone-#{Profiles::Presenter.tone_for(ada.public_slug)}[href=?]", player_path(ada.public_slug), 1 # (two players can share a tone: the address picks one out)
    handle = PublicProfile.handle_for(plain.public_slug)
    assert_select ".stage__crowd a.stage__fighter[href=?]", player_path(plain.public_slug), text: handle.first
    assert_select ".stage__tip-title", text: handle
    assert_select ".stage__crowd a[href*='#{ada.id}']", 0, "the address never carries the numeric id"
  end

  test "the aria-label is the words of the hover and focus card, and the card is hidden from assistive tech so nothing is said twice" do
    ada = live("ada", seconds: 7200, name: "Ada")
    ship_damage(ada, 3600, on: Time.current)
    other = live("closed", seconds: 3600)
    stage

    expected = "Ada: coded about 2 h in the last day, shipped a project: hit the boss. Click to see their profile."
    assert_select "a.stage__fighter[aria-label=?]", expected
    assert_select "a.stage__fighter[aria-label=?]", "#{PublicProfile.handle_for(other.public_slug)}: coded about 1 h in the last day, hits it with a steady pace. Click to see their profile."
    css_select(".stage__fan").each do |fan|
      circle = fan.at_css(".stage__fighter")
      tip = fan.at_css(".stage__tip")
      assert_nil circle["aria-describedby"], "the label already says it"
      assert_equal "true", tip["aria-hidden"]
      assert_equal circle["aria-label"].delete(":,."), tip.text.squish.delete(":,.")
    end
    assert_select ".stage__tip .stage__tip-title", "Ada"
    assert_select ".stage__tip .stage__tip-hint:not([hidden])", 2
    assert_select ".stage__tip .stage__tip-hint[hidden]", 0
  end

  test "your own circle gets the ring and the label, and says it is you" do
    @user.update!(profile_name: "Me")
    code_ago(@user, 1800, now: Time.current)
    live("other", seconds: 1800, name: "Zed")
    stage

    assert_select "li.stage__fan--you", 1
    assert_select "li.stage__fan--you .stage__you", "you"
    assert_select "li.stage__fan--you a[aria-label^=?]", "You (Me): coded about 30 min"
    assert_select "li.stage__fan--you .stage__tip .stage__tip-hint", "Click to see your profile"
    assert_select "li:not(.stage__fan--you) .stage__you", 0
  end

  test "nobody coded in the last day: no circles and no visible text, only the hidden sentence for assistive tech" do
    stage

    assert_select ".stage__crowd .stage__fan", 0
    assert_select ".stage__quiet", 0
    assert_select ".stage__arena p:not(.visually-hidden)", 0, "nothing printed over the boss"
    assert_select ".stage__arena p.visually-hidden[data-boss-fighters-target='arena']", text: /\ANobody has coded in the last day\. Be the first to hit it\./, count: 1
  end

  test "someone who coded 25 hours ago is not drawn" do
    live("stale", seconds: 1800, ago: 25.hours)
    stage

    assert_select ".stage__crowd .stage__fan", 0
    assert_select ".stage__quiet", 0
    assert_select ".stage__arena p.visually-hidden", text: /Nobody has coded in the last day/, count: 1
  end

  test "a defeated boss gets no 'be the first to hit it'" do
    @boss.update_columns(defeated_at: Time.current)
    stage

    assert_select ".stage__quiet", 0
    assert_select ".stage__arena p.visually-hidden", text: /\ANobody has coded in the last day\. .*Boss defeated\./, count: 1
    assert_select ".stage__arena p.visually-hidden", text: /be the first/i, count: 0
  end

  test "the stage is wired to the live controller and carries no inline script or style" do
    live("one", seconds: 1800, name: "Ada")
    stage

    assert_select "section.stage[data-controller~='boss-fighters'][data-boss-fighters-url-value=?]", boss_fighters_path
    %w[bar healthText summary plate name arena crowd].each { |target| assert_select "section.stage [data-boss-fighters-target='#{target}']", 1, target }
    assert_select "section.stage [style]", 0, "no inline styles (CSP)"
    assert_select "section.stage script", 0
    assert_select "section.stage [onclick], section.stage [onmouseover]", 0
  end

  test "the page names players by their chosen name or a handle, and never by a real name, email or Slack id" do
    closed = live("closed", seconds: 3600)
    stage

    [ "Real Name", "private.example.org", closed.slack_id, closed.hca_uid ].each { |secret| assert_not_includes response.body, secret }
    assert_includes response.body, PublicProfile.handle_for(closed.public_slug)
  end

  def motion_classes = css_select(".stage__crowd > li.stage__fan").to_h { |fan| [ fan["data-fighter-key"], fan["class"].split.grep(/\Astage__fan--(da|db|dc|de|ba|la|lb)\d+\z/).sort ] }

  test "every circle has its own rhythm, and the same person has the same one on every render" do
    10.times { |index| live("walker#{index}", seconds: 1800 + index) }
    live("slugger", seconds: 900).tap { |shipper| ship_damage(shipper, 3600, on: Time.current) }
    stage
    first = motion_classes
    stage
    second = motion_classes

    assert_equal 11, first.size
    assert first.values.all? { |classes| classes.size == Bosses::FighterMotion::STEPS.size }, "a class of each kind"
    assert_equal first, second, "same person, same rhythm"
    assert_equal 11, first.values.uniq.size, "no two circles move alike"
    first.each { |key, classes| assert_equal Bosses::FighterMotion.classes(Bosses::FighterMotion.for_key(key)).sort, classes }
    assert_operator css_select(".stage__crowd > li.stage__fan").map { |fan| fan["class"].split.grep(/\Astage__fan--da\d+\z/) }.uniq.size, :>, 3, "offsets differ"
    assert_operator css_select(".stage__crowd > li.stage__fan").map { |fan| fan["class"].split.grep(/\Astage__fan--dc\d+\z/) }.uniq.size, :>, 2, "speeds differ"
  end

  test "the live controller never writes data as HTML, and every stage animation sits behind prefers-reduced-motion" do
    js = Rails.root.join("app/javascript/controllers/boss_fighters_controller.js").read
    assert_no_match(/innerHTML|outerHTML|insertAdjacentHTML|document\.write/, js)
    assert_match(/boss:refresh/, js)
    assert_match(/visibilitychange/, js)
    assert_match(/turbo:before-cache/, Rails.root.join("app/views/dashboard/_stage.html.erb").read)

    css = Rails.root.join("app/assets/stylesheets/dashboard.css").read
    start = css.index("@media (prefers-reduced-motion: no-preference) {")
    depth = 0
    finish = (css.index("{", start)...css.length).find do |index|
      depth += 1 if css[index] == "{"
      depth -= 1 if css[index] == "}"
      depth.zero?
    end
    outside = css[0...start] + css[(finish + 1)..]
    assert_not outside.match?(/\banimation\s*:|\btransition\s*:/), "an animation or transition outside prefers-reduced-motion: no-preference"
    assert_match(/\.stage__fan\s*\{[^}]*transition:[^}]*inline-size[^}]*margin/m, css[start..finish], "size changes animate")
    assert_match(/stage__fan--hit-ship/, css[start..finish])
    assert_match(/\.stage__fan\s*\{[^}]*animation-delay:\s*var\(--delay\)/m, css[start..finish], "each circle starts at its own point")
    assert_no_match(/nth-child\(even\)\s*\{\s*animation-delay/, css, "no shared offset for half the circles")
    assert_no_match(/\bstyle\s*=/, Rails.root.join("app/views/dashboard/_fighter.html.erb").read, "the CSP has no style attributes")
    assert_no_match(/setAttribute\(["']style/, js)
  end
end
