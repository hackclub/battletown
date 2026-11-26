require "test_helper"
require_relative "../support/slack_profiles_helper"
require_relative "../support/fighters_helper"

# Slack names and pictures on the stage, the hover card and the profile page, and the signed-in-only avatar route.
class PlayerAvatarsTest < ActionDispatch::IntegrationTest
  include SlackProfilesHelper
  include FightersHelper
  include ActiveJob::TestHelper

  setup do
    @today = Time.current.utc.to_date
    @viewer = users(:onboarded)
    @viewer.update_columns(created_at: (@today - 30).in_time_zone("UTC"), signed_up_on: @today - 30)
    @boss = make_boss(starts_on: friday_on_or_before(@today), hp_seconds: 100 * HOUR)
    @owner = make_player("grace", name: "Gracie")
    @picture = picture_bytes(:webp, size: 128)
    @sha = Digest::SHA256.hexdigest(@picture)
    SlackProfile.create!(user: @owner, use_name: true, use_picture: true, display_name: "Gracie", picture: @picture, picture_sha256: @sha, picture_bytes: @picture.bytesize, status: "ok", fetched_at: Time.current)
  end

  teardown { reset_omniauth }

  def json = JSON.parse(response.body)

  # The Hack Club Auth claims carry the Slack id (User#apply_hca_claims copies it at every sign-in).
  def sign_in_with_slack_id(user, slack_id)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: { "slack_id" => slack_id } })
    post "/auth/hack_club"
    follow_redirect!
  end

  # The player uses "Use my Slack name and picture" (the default) and nothing has been fetched yet.
  def due_for_slack(user)
    SlackProfile.where(user_id: user.id).delete_all
    SlackProfile.create!(user: user, use_name: true, use_picture: true)
  end

  def avatar_path_for(user) = player_avatar_path(user.public_slug)

  # --- the route ---

  test "signed out goes home, not onboarded goes to onboarding" do
    get avatar_path_for(@owner)
    assert_redirected_to root_path
    sign_in_as users(:new_user)
    get avatar_path_for(@owner)
    assert_redirected_to onboarding_path
  end

  test "a signed-in player gets the stored WebP with private cache headers and nosniff, never a redirect to Slack" do
    sign_in_as @viewer
    get avatar_path_for(@owner)

    assert_response :success
    assert_equal "image/webp", response.media_type
    assert_equal @picture.b, response.body.b
    assert_includes response.headers["Cache-Control"], "private"
    assert_not_includes response.headers["Cache-Control"], "public"
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "inline", response.headers["Content-Disposition"].to_s.split(";").first

    etag = response.headers["ETag"]
    get avatar_path_for(@owner), headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "unknown, malformed and picture-less slugs are one identical 404" do
    plain = make_player("plain", name: "Plain")
    nopic = make_player("nopic", name: "Nopic")
    SlackProfile.create!(user: nopic, status: "ok") # a row, but no picture was ever stored
    off = make_player("off", name: "Off")
    SlackProfile.create!(user: off, use_picture: false, picture: @picture, picture_sha256: @sha, picture_bytes: @picture.bytesize, status: "ok")
    sign_in_as @viewer

    responses = [ "zzzzzzzzzzz", "x", "x%20y", plain.public_slug, nopic.public_slug, off.public_slug ].map do |slug|
      get "/players/#{ERB::Util.url_encode(slug)}/avatar"
      assert_response :not_found, slug
      # (the test environment answers with Rails's own exception page, which quotes the request; production serves public/404.html)
      [ response.status, response.media_type, css_select("title, h1, h2").map { |node| node.text.squish }, response.headers["Cache-Control"] ]
    end
    assert_equal 1, responses.uniq.size, "the answers must not tell a switched-off avatar from an unknown one"
  end

  test "any signed-in, onboarded player can load any player's picture" do
    other = make_player("another")
    sign_in_as other
    get avatar_path_for(@owner)
    assert_response :success
    assert_equal @picture.b, response.body.b
  end

  test "a player with a picture: the page uses our address, never Slack's" do
    sign_in_as @viewer
    get player_path(@owner.public_slug)

    assert_response :success
    assert_select "img.avatar__img[src^='/players/#{@owner.public_slug}/avatar']", 1
    assert_match %r{\A/players/#{@owner.public_slug}/avatar\?v=#{@sha.first(10)}\z}, css_select("img.avatar__img").first["src"]
    assert_not_includes response.body, "slack-edge.com"
    assert_not_includes response.body, "avatars.slack"
  end

  test "without a stored picture the profile page keeps the generated initial" do
    due_for_slack(@owner)
    sign_in_as @viewer
    get player_path(@owner.public_slug)
    assert_select "img.avatar__img", 0
    assert_select ".avatar--lg", text: "G"
  end

  # --- the stage ---

  def live(key, **args) = fighter(key, now: Time.current, **args)

  test "the fighters JSON carries name, link and avatar_url for every fighter; avatar_url only for one who has a picture, and the stage and card use it" do
    with_picture = live("pic", seconds: 7200, name: "Pic")
    SlackProfile.create!(user: with_picture, use_picture: true, picture: @picture, picture_sha256: @sha, picture_bytes: @picture.bytesize, status: "ok")
    plain = live("plain", seconds: 3600, name: "Plain")
    unnamed = live("unnamed", seconds: 1800)
    SlackProfile.create!(user: unnamed, display_name: "Slacky", picture: @picture, picture_sha256: @sha, picture_bytes: @picture.bytesize, status: "ok")
    switched_off = live("off", seconds: 1800, name: "Off")
    SlackProfile.create!(user: switched_off, use_picture: false, picture: @picture, picture_sha256: @sha, picture_bytes: @picture.bytesize, status: "ok")
    sign_in_as @viewer

    get boss_fighters_path
    circles = json["fighters"]
    assert_equal 4, circles.size
    circles.each do |circle|
      assert circle["name"].present? && circle["path"].start_with?("/players/") && circle["initial"].present?, circle.inspect
    end
    by_name = circles.index_by { |circle| circle["name"] }
    assert_equal "/players/#{with_picture.public_slug}/avatar?v=#{@sha.first(10)}", by_name["Pic"]["avatar_url"]
    assert_equal "/players/#{plain.public_slug}", by_name["Plain"]["path"]
    assert_nil by_name["Plain"]["avatar_url"]
    assert_nil by_name["Off"]["avatar_url"]
    assert_equal "/players/#{unnamed.public_slug}/avatar?v=#{@sha.first(10)}", by_name["Slacky"]["avatar_url"], "no chosen name: the Slack name and picture"
    assert_not_includes response.body, "slack-edge.com"

    get dashboard_path
    assert_response :success
    assert_equal [ "/players/#{with_picture.public_slug}/avatar?v=#{@sha.first(10)}", "/players/#{unnamed.public_slug}/avatar?v=#{@sha.first(10)}" ].sort,
                 css_select("a.stage__fighter img.avatar__img").map { |img| img["src"] }.sort
    assert_select ".stage__tip-title", text: "Pic"
    assert_select "a.stage__fighter", 4
    assert_not_includes response.body, "slack-edge.com"
  end

  test "a blank Slack display name stores nothing: the real name is never read, so the handle is shown on the page and the stage" do
    blank = live("blank", seconds: 3600)
    blank.update_columns(slack_id: "U0BLANK001")
    SlackProfile.create!(user: blank, use_name: true, use_picture: false)
    with_bot_token do
      with_network(slack_router(info: slack_ok(name: "", real_name: "Maya Real Name"))) do
        assert_equal :ok, SlackProfiles::Refresh.call(blank).status
      end
    end
    assert_nil SlackProfile.find_by!(user_id: blank.id).display_name
    assert_not_includes SlackProfile.where(user_id: blank.id).pluck(:display_name).join, "Maya"

    handle = PublicProfile.handle_for(blank.public_slug)
    sign_in_as @viewer
    get player_path(blank.public_slug)
    assert_response :success
    assert_select "h1", handle
    assert_not_includes response.body, "Maya Real Name"
    get boss_fighters_path
    assert_includes json["fighters"].map { |circle| circle["name"] }, handle
    assert_not_includes response.body, "Maya Real Name"
    get dashboard_path
    assert_not_includes response.body, "Maya Real Name"
  end

  # --- queueing (never blocks, never fails) ---

  test "signing in and opening the dashboard queue at most one background fetch, and only for an eligible player" do
    @owner.update_columns(slack_id: "U0GRACE001")
    due_for_slack(@owner)
    with_bot_token do
      assert_enqueued_with(job: SlackProfileJob, args: [ @owner.id ]) { sign_in_with_slack_id(@owner, "U0GRACE001") }
      clear_enqueued_jobs
      assert_enqueued_jobs 1, only: SlackProfileJob do
        get dashboard_path
      end
    end
  end

  test "no job is queued without the token, without a Slack id, or when the player turned the choice off" do
    @owner.update_columns(slack_id: "U0GRACE001")
    due_for_slack(@owner)
    with_env("SLACK_BOT_TOKEN" => nil) do
      assert_no_enqueued_jobs(only: SlackProfileJob) { sign_in_with_slack_id(@owner, "U0GRACE001") }
    end
    with_bot_token do
      plain = make_player("nope", name: "Nope")
      plain.update_columns(slack_id: nil)
      assert_no_enqueued_jobs(only: SlackProfileJob) { SlackProfiles.refresh_later(plain) }

      SlackProfiles::Choice.set(@owner, use_slack: false)
      assert_no_enqueued_jobs(only: SlackProfileJob) { SlackProfiles.refresh_later(@owner) }
    end
  end

  test "the Slack choice is on by default: a player with a Slack id and no row is fetched, with no opt-in anywhere" do
    plain = make_player("plain", name: "Plain")
    plain.update_columns(slack_id: "U0PLAIN001")
    with_bot_token do
      assert SlackProfiles::Choice.use_slack?(plain)
      assert_enqueued_with(job: SlackProfileJob, args: [ plain.id ]) { SlackProfiles.refresh_later(plain) }
      assert_includes SlackProfiles.due_scope.pluck(:id), plain.id
      with_network(slack_router) do |seen|
        assert_equal :ok, SlackProfiles::Refresh.call(plain).status
        assert_equal [ "slack.com", "avatars.slack-edge.com" ], seen.hosts
      end
    end
    assert SlackProfile.find_by(user_id: plain.id)&.picture?
  end

  test "a broken queue never fails sign-in" do
    @owner.update_columns(slack_id: "U0GRACE001")
    due_for_slack(@owner)
    with_bot_token do
      stub_method(SlackProfileJob, :perform_later, ->(*) { raise "queue down" }) do
        sign_in_with_slack_id(@owner, "U0GRACE001")
        assert_response :redirect
      end
    end
  end

  # --- Settings ---

  test "Settings offers the choice, on until unticked, and saving it off deletes the copy; a typed display name stays when it is on" do
    plain = make_player("plain", name: "Plain")
    sign_in_as plain
    get settings_path
    assert_select "#profile input[type=checkbox][name=use_slack]", 1
    assert_select "#profile input[type=checkbox][name=use_slack][checked]", 1
    assert_select "#use_slack_hint", /Off: they see a coloured circle/

    sign_in_as @owner
    get settings_path
    assert_select "#profile input[type=checkbox][name=use_slack][checked]", 1
    assert_select "#profile", text: /Use my Slack name and picture/

    patch settings_profile_path, params: { profile_name: "Gracie", use_slack: "0" }
    assert_redirected_to settings_path(anchor: "profile")
    profile = SlackProfile.find_by!(user_id: @owner.id)
    assert_not profile.picture?
    assert_not profile.use_picture
    assert_not profile.use_name

    patch settings_profile_path, params: { profile_name: "Gracie", use_slack: "1" }
    assert SlackProfile.find_by!(user_id: @owner.id).use_picture

    patch settings_profile_path, params: { profile_name: "Grace H", use_slack: "1" }
    assert_equal "Grace H", @owner.reload.profile_name
    assert SlackProfile.find_by!(user_id: @owner.id).use_name, "a typed name no longer switches the Slack choice off, it just wins"
    assert SlackProfile.find_by!(user_id: @owner.id).use_picture
  end

  test "the admin user page shows the status without a name or picture" do
    SlackProfile.where(user_id: @owner.id).update_all(status: "missing_scope")
    assert_equal "missing_scope", SlackProfile.for(@owner).status
  end
end
