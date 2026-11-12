require "test_helper"
require_relative "../support/coins_helper"
require_relative "../support/ships_test_support"

# The crew pages, the invite link, the dashboard card and the admin list, with the `team` flag on and off.
class TeamTest < ActionDispatch::IntegrationTest
  include CoinsHelper
  include ShipsTestSupport

  NOW = Time.utc(2026, 11, 10, 12)

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @ann = users(:onboarded)
    @ann.update_columns(display_name: "Ann Example", email: "ann.private@example.com", slack_id: "UANNPRIVATE1")
    @ben = users(:new_user)
    @ben.update_columns(display_name: "Ben Example", email: "ben.private@example.com", slack_id: "UBENPRIVATE2", onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def switch_to(user)
    delete logout_path
    sign_in_as(user)
  end

  def start_crew(user = @ann, name: nil)
    Flipper.enable(:team)
    Teams::Crew.create!(user: user, name: name)
  end

  # --- the flag off: nothing exists ---

  test "with the flag off every crew route is a 404, signed in or not, and nothing is written" do
    team = start_crew
    Flipper.disable(:team)
    token = team.invite_token
    ENV["ADMIN_HCA_UIDS"] = @ann.hca_uid

    [ nil, @ann, @ben ].each do |visitor|
      switch_to(visitor) if visitor
      { get: [ "/team", "/team/join/#{token}", "/admin/teams" ], post: [ "/team", "/team/invite", "/team/join/#{token}" ],
        patch: [ "/team" ], delete: [ "/team/leave", "/admin/teams/#{team.id}" ] }.each do |verb, paths|
        paths.each do |path|
          send(verb, path)
          assert_response :not_found, "#{verb.upcase} #{path} must be a 404 while the flag is off"
        end
      end
    end
    assert_equal [ 1, 1 ], [ Team.count, TeamMembership.count ]
  end

  test "with the flag off the dashboard shows no crew card and the admin dashboard no Crews link" do
    ENV["ADMIN_HCA_UIDS"] = @ann.hca_uid
    sign_in_as @ann
    get dashboard_path
    assert_response :success
    assert_no_match(/Invite a buddy/, response.body)
    assert_no_match(%r{href="/team"}, response.body)
    get admin_root_path
    assert_no_match(%r{/admin/teams}, response.body)
  end

  test "with the flag off an approved ship shows no crew line" do
    start_crew
    Flipper.disable(:team)
    sign_in_as @ann
    get dashboard_path
    assert_no_match(/crew bonus/i, response.body)
  end

  # --- the crew page ---

  test "signed-out and not-yet-onboarded visitors are turned away from the crew page" do
    Flipper.enable(:team)
    get team_path
    assert_redirected_to root_path
    @ben.update_columns(onboarded_at: nil, onboarding_step: 1)
    sign_in_as @ben
    get team_path
    assert_redirected_to onboarding_path
  end

  test "someone without a crew sees how it works and can start one with an optional name" do
    Flipper.enable(:team)
    sign_in_as @ann
    get team_path
    assert_response :success
    assert_select "h1", "Code with friends"
    assert_match(/5%/, response.body)
    assert_select "form[action='#{team_path}'] input[type=submit][value='Start a crew']"

    post team_path, params: { team: { name: "Night owls" } }
    assert_redirected_to team_path
    follow_redirect!
    assert_select "h2", "Night owls"
    assert_equal "Night owls", TeamMembership.find_by!(user_id: @ann.id).team.name
    assert_match %r{/team/join/#{Team::TOKEN_FORMAT_PATH.source}}, response.body
  end

  test "a name that is too long is refused with a friendly message and no crew is left behind" do
    Flipper.enable(:team)
    sign_in_as @ann
    post team_path, params: { team: { name: "x" * 60 } }
    assert_redirected_to team_path
    follow_redirect!
    assert_match(/up to 40 characters/, response.body)
    assert_equal 0, Team.count
  end

  test "the crew page lists display names only: no email, Slack id, hours or coins of a crewmate" do
    team = start_crew
    Teams::Crew.join!(user: @ben, token: team.invite_token)
    code(@ben, Date.new(2026, 11, 8), 5 * HOUR)
    Coins::Ledger.credit(user: @ben, amount: 4321, kind: "adjustment", idempotency_key: "leak-check")
    sign_in_as @ann
    get team_path

    assert_response :success
    assert_select ".team__members li", 2
    assert_match(/Ann Example \(you\)/, response.body)
    assert_match(/Ben Example/, response.body)
    %w[ben.private@example.com ann.private@example.com UBENPRIVATE2 UANNPRIVATE1 4321 4,321 ident!new ident!onboarded].each do |secret|
      assert_not_includes response.body, secret
    end
    assert_no_match(/5 hours|5h|18000/, response.body)
  end

  test "nobody can open another crew's page: the page is always your own, and there is no id to change" do
    Flipper.enable(:team)
    start_crew(@ann, name: "Ann's secret crew")
    sign_in_as @ben
    get team_path
    assert_response :success
    assert_no_match(/Ann's secret crew|Ann Example/, response.body)
    assert_select "h2", "Start a crew"
    %w[/team/1 /teams /teams/1 /team/members /team/1/leave].each do |path|
      get path
      assert_response :not_found, "GET #{path}"
    end
  end

  test "any member can make a new invite link, which kills the old one" do
    team = start_crew
    old = team.invite_token
    sign_in_as @ann
    post invite_team_path
    assert_redirected_to team_path
    assert_not_equal old, team.reload.invite_token

    switch_to(@ben)
    get team_join_path(old)
    assert_response :not_found
    get team_join_path(team.invite_token)
    assert_response :success
  end

  test "leaving takes the member out, says coins stay, and the cooldown stops an instant new crew" do
    team = start_crew
    Teams::Crew.join!(user: @ben, token: team.invite_token)
    sign_in_as @ben
    delete leave_team_path
    assert_redirected_to team_path
    follow_redirect!
    assert_match(/Coins you already earned stay yours/, response.body)
    assert_match(/You left a crew recently/, response.body)
    assert_not TeamMembership.exists?(user_id: @ben.id)
    assert_select "form[action='#{team_path}'] input[type=submit][value='Start a crew']", 0

    post team_path
    follow_redirect!
    assert_match(/left a crew recently/, response.body)
    assert_equal 1, Team.count
  end

  test "renaming only changes your own crew" do
    mine = start_crew(@ann, name: "Before")
    theirs = start_crew(@ben, name: "Theirs")
    sign_in_as @ann
    patch team_path, params: { team: { name: "After" }, id: theirs.id }
    assert_equal "After", mine.reload.name
    assert_equal "Theirs", theirs.reload.name
  end

  # --- the invite link ---

  test "the invite page names the inviter's display name, says what is shared, and joins only on the button" do
    team = start_crew
    sign_in_as @ben
    get team_join_path(team.invite_token)

    assert_response :success
    assert_select "h1", "Join Ann Example's crew?"
    assert_match(/display name/, response.body)
    assert_match(/no hours, coins, Slack id or email/, response.body)
    assert_no_match(/ann.private@example.com|UANNPRIVATE1/, response.body)
    assert_equal 1, team.memberships.count, "just opening the link joins nothing"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "noindex", response.headers["X-Robots-Tag"]

    post team_join_path(team.invite_token)
    assert_redirected_to team_path
    assert_equal 2, team.memberships.count
  end

  test "the invite link needs a signed-in, onboarded person and shows nothing to anyone else" do
    team = start_crew
    get team_join_path(team.invite_token)
    assert_redirected_to root_path
    assert_no_match(/Ann Example/, flash.to_h.to_s)

    post team_join_path(team.invite_token)
    assert_redirected_to root_path
    assert_equal 1, team.memberships.count

    @ben.update_columns(onboarded_at: nil, onboarding_step: 1)
    sign_in_as @ben
    get team_join_path(team.invite_token)
    assert_redirected_to onboarding_path
  end

  test "an unknown, malformed, expired or replaced token is one and the same 404 page" do
    team = start_crew
    team.update_columns(invite_expires_at: 1.minute.ago)
    sign_in_as @ben
    bodies = [ "x" * 16, "A" * 24, team.invite_token ].map do |token|
      get team_join_path(token)
      assert_response :not_found
      Nokogiri::HTML(response.body).at_css("main").text.squish
    end
    assert_equal 1, bodies.uniq.size, "an expired link must look exactly like one that never existed"
    assert_match(/does not work/, bodies.first)
    assert_no_match(/Ann Example/, bodies.first)

    [ "short", "a" * 40, "ab%20cd" + "e" * 12 ].each do |token|
      get "/team/join/#{token}"
      assert_response :not_found
    end
    post team_join_path(team.invite_token)
    assert_response :not_found
    assert_equal 1, team.memberships.count
  end

  test "joining a full crew, while in another crew, or during the cooldown is refused with the reason" do
    team = start_crew
    (Teams::Config.current.max_size - 1).times { Teams::Crew.join!(user: build_user, token: team.invite_token) }
    sign_in_as @ben
    get team_join_path(team.invite_token)
    assert_match(/This crew is full/, response.body)
    assert_select "form[action='#{team_join_path(team.invite_token)}']", 0
    post team_join_path(team.invite_token)
    assert_response :unprocessable_content
    assert_match(/full/, response.body)

    other = start_crew(@ben)
    assert other.persisted?
    get team_join_path(team.invite_token)
    assert_match(/already in a crew/, response.body)
  end

  test "someone already in the crew who opens its link is taken to the crew page" do
    team = start_crew
    sign_in_as @ann
    get team_join_path(team.invite_token)
    assert_redirected_to team_path
  end

  # --- the dashboard card, the ship page and the admin list ---

  test "the dashboard card invites a buddy, then shows the crew size and the person's own bonus coins" do
    Flipper.enable(:team)
    sign_in_as @ann
    get dashboard_path
    assert_select ".dash-team a[href='#{team_path}']", text: "Invite a buddy"

    team = start_crew
    Teams::Crew.join!(user: @ben, token: team.invite_token)
    ship = approved_ship_with_team_bonus
    get dashboard_path
    assert_select ".dash-team", text: /2 of 5 people/
    assert_select ".dash-team", text: /#{ship.team_payout.coins} coins/
    assert_no_match(/Ben Example/, css_select(".dash-team").to_s)
  end

  test "an approved ship shows the crew bonus as its own line" do
    start_crew
    Teams::Crew.join!(user: @ben, token: Team.first.invite_token)
    ship = approved_ship_with_team_bonus
    sign_in_as @ann
    get ship_path(ship)
    assert_response :success
    assert_match(/crew bonus, paid separately/, response.body)
  end

  test "the admin list shows sizes and total coins paid, no names or hours, to admins only" do
    team = start_crew(@ann, name: "Night owls")
    Teams::Crew.join!(user: @ben, token: team.invite_token)
    approved_ship_with_team_bonus
    paid = TeamPayout.sum(:coins)
    assert_operator paid, :>, 0

    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    switch_to(@ann)
    get admin_teams_path
    assert_response :not_found

    ENV["ADMIN_HCA_UIDS"] = @ann.hca_uid
    get admin_teams_path
    assert_response :success
    assert_match(/Night owls/, response.body)
    assert_match(/2 of 5/, response.body)
    assert_match(/#{paid}/, response.body)
    assert_select ".admin-only"
    %w[Ann\ Example Ben\ Example ann.private@example.com UANNPRIVATE1].each { |text| assert_not_includes response.body, text }

    delete admin_team_path(team)
    assert_redirected_to admin_teams_path
    assert_equal 0, TeamMembership.count
    assert_equal paid, CoinTransaction.where(kind: "team_bonus").sum(:amount), "dissolving a crew keeps the coins"
    assert_equal paid, TeamPayout.sum(:coins)
  end

  test "the admin dashboard links to the crews list while the flag is on" do
    Flipper.enable(:team)
    ENV["ADMIN_HCA_UIDS"] = @ann.hca_uid
    sign_in_as @ann
    get admin_root_path
    assert_select "a[href='#{admin_teams_path}']", text: "Crews"
  end

  private

  # Ann's ship (4 hours on each of Nov 1 to 3) approved while both are in the crew; Ben coded on Nov 1 and 2.
  def approved_ship_with_team_bonus
    @ann.update_columns(created_at: Time.utc(2026, 10, 1, 12), signed_up_on: Date.new(2026, 10, 1))
    @ben.update_columns(created_at: Time.utc(2026, 10, 1, 12), signed_up_on: Date.new(2026, 10, 1))
    TeamMembership.update_all(joined_at: Time.utc(2026, 10, 31, 9))
    project = make_project(@ann)
    (1..3).each { |day| code(@ann, Date.new(2026, 11, day), 4 * HOUR) }
    (1..2).each { |day| code(@ben, Date.new(2026, 11, day), HOUR) }
    ship = submit_ship(project)
    Ships::Approve.call(ship: ship, reviewer: @ben, approved_seconds: ship.coded_seconds, now: NOW)
    ship.reload
  end
end
