require "test_helper"
require_relative "../support/profiles_helper"

# Player profiles (always visible to signed-in, onboarded players): who may open one, what it shows, and (above all) what it never shows.
class ProfilesTest < ActionDispatch::IntegrationTest
  include ProfilesHelper

  setup do
    travel_to Time.utc(2026, 11, 15, 12) # a Sunday inside the boss week Friday Nov 13 to Thursday Nov 19
    @boss = make_boss
    @viewer = users(:onboarded)
    @owner = make_player("gracehopper", name: "Gracie", display_name: "Grace Brewster Hopper")
  end

  teardown do
    reset_omniauth
    travel_back
  end

  def page_text = css_select("main").text.squish

  # --- who may open it ---

  test "a signed-out visitor is sent to sign in, and someone who has not finished onboarding to onboarding" do
    get player_path(@owner.public_slug)
    assert_redirected_to root_path
    get profile_path
    assert_redirected_to root_path
    sign_in_as users(:new_user)
    get player_path(@owner.public_slug)
    assert_redirected_to onboarding_path
    get profile_path
    assert_redirected_to onboarding_path
  end

  test "any signed-in, onboarded player can open any player's profile (there is no opt-in and no opt-out)" do
    sign_in_as @viewer
    get player_path(@owner.public_slug)
    assert_response :success
    assert_select "title", "Gracie - Battletown"
    assert_select "h1", "Gracie"
    assert_select ".avatar[aria-hidden=true]", text: "G"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".profile__note", 0, "someone else's page has no owner note"
  end

  test "a player who chose no name is shown by a generated handle, never their real name" do
    plain = make_player("plainjane", display_name: "Jane Plain Realname")
    sign_in_as @viewer
    get player_path(plain.public_slug)
    assert_response :success
    handle = PublicProfile.handle_for(plain.public_slug)
    assert_select "h1", handle
    assert_select "title", "#{handle} - Battletown"
    assert_not_includes response.body, "Jane"
    assert_not_includes response.body, "Realname"
  end

  test "a player's Slack name is their name when they chose none, and what they chose wins over it" do
    plain = make_player("slackjane")
    SlackProfile.create!(user_id: plain.id, display_name: "Janey")
    sign_in_as @viewer
    get player_path(plain.public_slug)
    assert_select "h1", "Janey"
    plain.update!(profile_name: "Jane C")
    get player_path(plain.public_slug)
    assert_select "h1", "Jane C"
  end

  test "an unknown address and a malformed one are the same plain 404" do
    sign_in_as @viewer
    responses = [ "abcdefghijk", "zzzzzzzzzzz", "short", "a" * 64, "..%2F..", "x%20y", @owner.public_slug.upcase ].map do |slug|
      get "/players/#{slug}"
      assert_response :not_found, slug
      # (the test environment answers with Rails's own exception page, which quotes the request; production serves public/404.html)
      [ response.status, response.media_type, css_select("title, h1, h2").map { |node| node.text.squish }, response.headers["Cache-Control"] ]
    end
    assert_equal 1, responses.uniq.size, "the answers must not tell one kind of bad address from another"
    assert_equal 404, responses.first.first
  end

  test "signed-out visitors and players who have not finished onboarding get the same answer for a real address and an unknown one" do
    answers = [ @owner.public_slug, "abcdefghijk", "short" ].map do |slug|
      get "/players/#{slug}"
      [ response.status, response.location ]
    end
    assert_equal 1, answers.uniq.size
    assert_equal [ 302, "http://www.example.com/" ], answers.first
    sign_in_as users(:new_user)
    answers = [ @owner.public_slug, "abcdefghijk", "short" ].map do |slug|
      get "/players/#{slug}"
      [ response.status, response.location ]
    end
    assert_equal 1, answers.uniq.size
    assert_equal [ 302, onboarding_url ], answers.first
  end

  test "the owner sees their own page with the Edit in Settings link" do
    sign_in_as @owner
    get player_path(@owner.public_slug)
    assert_response :success
    assert_select ".profile__note", /as other players see it/
    assert_select ".profile__note", /Other players can see your name, projects and boss damage/
    assert_select ".profile__note a[href='#{settings_path(anchor: 'profile')}']"
  end

  test "players cannot reach a profile by its numeric id or by display name" do
    sign_in_as @viewer
    [ "/players/#{@owner.id}", "/players/Gracie", "/players/Grace%20Brewster%20Hopper", "/profile/#{@owner.id}", "/users/#{@owner.id}" ].each do |path|
      get path
      assert_response :not_found, path
    end
  end

  test "/profile is my own page: straight to /players/:slug" do
    sign_in_as @viewer
    get profile_path
    assert_redirected_to player_path(@viewer.public_slug)
    follow_redirect!
    assert_select "h1", PublicProfile.handle_for(@viewer.public_slug)
    assert_select ".profile__note", /as other players see it/
  end

  # --- what it shows ---

  test "damage this week and all-time equal what Bosses::Damage says, and bosses slain counts the badge" do
    project = make_project(@owner, "Cow physics")
    ship_for(project, seconds: 2 * 3600, on: Date.new(2026, 11, 14))
    ship_for(make_project(@owner, "Older"), seconds: 3 * 3600, on: Date.new(2026, 11, 6)) # a week before any boss
    old_boss = make_boss(starts_on: Date.new(2026, 11, 6))
    ship_for(make_project(@owner, "Again"), seconds: 900, on: Date.new(2026, 11, 9), status: "approved")
    old_boss.update!(defeated_at: Time.utc(2026, 11, 9))
    ship_for(make_project(@owner, "Draft"), seconds: 10 * 3600, status: "draft")
    ship_for(make_project(@owner, "Rejected"), seconds: 10 * 3600, status: "rejected")

    sign_in_as @viewer
    get player_path(@owner.public_slug)
    week = Bosses::Damage.for_user(@boss, @owner)
    assert_equal 2 * 3600, week
    all_time = Bosses::Damage.all_time_for_user(@owner)
    assert_equal (2 * 3600) + (3 * 3600) + 900, all_time
    stats = css_select(".profile__stat").to_h { |stat| [ stat.at_css("dt").text.squish, stat.at_css("dd").text.squish ] }
    assert_equal helper_hours(week), stats["This boss week (#{@boss.name})"]
    assert_equal helper_hours(all_time), stats["All-time"]
    assert_equal "1", stats["Bosses slain"]
  end

  def helper_hours(seconds) = ApplicationController.helpers.ship_hours(seconds)

  test "the 15-minute streak is the dashboard's number" do
    add_hours(@owner, Date.new(2026, 11, 15), 20 * 60)
    add_hours(@owner, Date.new(2026, 11, 14), 20 * 60)
    sign_in_as @viewer
    get player_path(@owner.public_slug)
    assert_select ".profile__stat dd", text: "2 days"
    assert_select ".profile__since", "Fighting since September 2026"
  end

  test "projects: newest first, live only, with ship counts and the latest status of handed-in ships, links only when present and https" do
    old = make_project(@owner, "Old game", repo_url: "https://github.com/octo/old", created_at: 3.days.ago)
    fresh = make_project(@owner, "Fresh site", kind: "website", demo_url: "https://fresh.example.org/play", idea: "SECRET-IDEA-TEXT", created_at: 1.day.ago)
    archived = make_project(@owner, "Hidden thing")
    archived.update_columns(status: "archived")
    ship_for(old, seconds: 1800, on: Date.new(2026, 11, 13), status: "approved")
    ship_for(old, seconds: 1800, on: Date.new(2026, 11, 14))
    ship_for(old, seconds: 1800, on: Date.new(2026, 11, 12), status: "rejected")
    ship_for(fresh, seconds: 1800, status: "draft")

    sign_in_as @viewer
    get player_path(@owner.public_slug)
    names = css_select(".profile__project-name").map { |node| node.text.squish }
    assert_equal [ "Fresh site", "Old game" ], names
    assert_no_match(/Hidden thing|SECRET-IDEA-TEXT/, response.body)
    cards = css_select(".profile__project")
    assert_match(/No ships yet/, cards[0].text) # a draft is not a ship others can see
    assert_match(/2 ships/, cards[1].text)
    assert_select ".profile__project:nth-child(2) .ship-status", text: "Waiting for review"
    assert_select "a[href='https://fresh.example.org/play'][rel='noopener noreferrer']", "Demo"
    assert_select "a[href='https://github.com/octo/old'][rel='noopener noreferrer']", "GitHub"
    assert_select "a[target]", 0
  end

  test "only an https address ever becomes a link (the database refuses the rest, and the helper checks again)" do
    helpers = ApplicationController.helpers
    assert_nil helpers.profile_external_link("x", "javascript:alert(1)")
    assert_nil helpers.profile_external_link("x", "http://insecure.example.org")
    assert_nil helpers.profile_external_link("x", nil)
    assert_includes helpers.profile_external_link("x", "https://ok.example.org"), 'rel="noopener noreferrer"'
    assert_not_includes helpers.profile_external_link("x", "https://ok.example.org"), "target"
  end

  test "someone else's page has no manage links and no ship list; mine has both" do
    project = make_project(@owner, "Cow physics")
    ship = ship_for(project, status: "approved")
    sign_in_as @viewer
    get player_path(@owner.public_slug)
    assert_select "main a[href='#{projects_path}']", 0
    assert_select "main a[href='#{ship_path(ship)}']", 0
    assert_no_match(/My ships/, response.body)
    delete logout_path
    sign_in_as @owner
    get profile_path
    follow_redirect!
    assert_select "main a[href='#{projects_path}']", "Manage projects"
    assert_select "h2", "My ships"
    assert_select "main a[href='#{ship_path(ship)}']"
    assert_select ".profile__ships .ship-status", text: "Approved"
  end

  # --- no leaks ---

  test "a profile never contains the email, Slack id, real name, ids, schedule, coins, prize or an outside image" do
    project = make_project(@owner, "Cow physics", idea: "A private idea about cows")
    ship_for(project, status: "approved")
    CoinTransaction.create!(user: @owner, amount: 777, kind: "refund", idempotency_key: "profile-leak")
    @owner.update_columns(coding_time: "03:17", prize_key: "tshirt")
    add_hours(@owner, Date.new(2026, 11, 13), 4 * 3600 + 17 * 60) # per-day hours are private: only damage and the streak are shown
    sign_in_as @viewer
    get player_path(@owner.public_slug)
    assert_response :success
    body = response.body
    [ @owner.email, @owner.slack_id, "Grace Brewster Hopper", "Grace", "Hopper", @owner.hca_uid, "gracehopper@", "03:17", "A private idea", "T-shirt", "tshirt" ].each do |secret|
      assert_not_includes body, secret, "leaked #{secret}"
    end
    assert_no_match(/\b777\b|coins?\b/i, page_text)
    assert_no_match(/4 ?h(ours?)? 17|4:17|\b257\b|15377|\b4\.28/, page_text, "no per-day hours")
    # Only addresses and form or data values are checked: the words ("1 hour", "1 ship") legitimately hold small numbers.
    markup = body.gsub(/<(script|style)\b.*?<\/\1>/m, "")
    addresses = markup.scan(/\s(?:href|src|srcset|action|value|data-[\w-]*(?:url|path|id|user|project|ship|slug))="([^"]*)"/i).flatten
    [ @owner.id, project.id, Ship.find_by!(project: project).id, @viewer.id ].each do |id|
      addresses.each { |value| assert_no_match(%r{(?<![\w.-])#{id}(?![\w.-])}, value, "the id #{id} shows up in #{value}") }
    end
    assert_select "main img", 0
    assert_no_match(%r{(src|srcset|url\()\s*=?\s*["']?https?://}i, body)
    assert_no_match(/gravatar|slack-edge|avatars\./i, body)
    assert_select "[style]", 0
  end

  test "even a real name typed as the profile name is the owner's choice, but the email and Slack id never appear" do
    @owner.update!(profile_name: "Grace Hopper")
    sign_in_as @viewer
    get player_path(@owner.public_slug)
    assert_select "h1", "Grace Hopper"
    assert_not_includes response.body, @owner.email
    assert_not_includes response.body, @owner.slack_id
  end

  # --- cost ---

  test "the page runs a bounded number of queries, however many projects and ships there are" do
    make_project(@owner, "First")
    sign_in_as @viewer
    get player_path(@owner.public_slug) # warm up (session, flags)
    few = count_queries { get player_path(@owner.public_slug) }
    8.times { |i| ship_for(make_project(@owner, "Project #{i}"), on: Date.new(2026, 11, 13 + (i % 4)), status: i.even? ? "approved" : "submitted") }
    many = count_queries { get player_path(@owner.public_slug) }
    assert_equal few, many, "the number of queries must not grow with projects or ships"
    assert_operator many, :<=, 30
    assert_equal 9, css_select(".profile__project").size
  end
end
