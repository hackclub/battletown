require "test_helper"
require_relative "../../support/slack_profiles_helper"

class SlackProfiles::RefreshTest < ActiveSupport::TestCase
  include SlackProfilesHelper

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown { Rails.cache = @original_cache }

  def refresh(user, router = slack_router, now: Time.current)
    outcome = nil
    network = nil
    with_bot_token do
      with_network(router) do |seen|
        outcome = SlackProfiles::Refresh.call(user, now: now)
        network = seen
      end
    end
    [ outcome, network ]
  end

  test "happy path: stores a sanitised name and a re-encoded 128 px WebP, calls users.info once with the bot token" do
    user = slack_player
    outcome, network = refresh(user)

    assert_equal :ok, outcome.status
    profile = SlackProfile.find_by!(user_id: user.id)
    assert_equal "ok", profile.status
    assert_equal "Maya", profile.display_name
    assert profile.picture?
    image = Vips::Image.webpload_buffer(profile.picture)
    assert_equal [ 128, 128 ], [ image.width, image.height ]
    assert_equal Digest::SHA256.hexdigest(profile.picture), profile.picture_sha256
    assert_operator profile.picture_bytes, :<=, SlackProfile::MAX_PICTURE_BYTES
    assert_equal "Maya", user.reload.profile_name

    info = network.calls_to("slack.com").sole
    assert_match %r{\A/api/users\.info\?user=U0}, info[:path]
    assert_equal "Bearer #{TOKEN}", info[:authorization]
    assert_equal %w[slack.com avatars.slack-edge.com], network.hosts
    assert_nil network.calls_to("avatars.slack-edge.com").sole[:authorization], "the bot token is never sent to the picture host"
  end

  test "the picture is stored as a clean WebP: no metadata and nothing appended survives" do
    exif = picture_bytes(:jpeg)
    polyglot = exif + "<script>alert(1)</script>".b
    user = slack_player
    refresh(user, slack_router(picture: StreamResponse.new(200, polyglot)))

    stored = SlackProfile.find_by!(user_id: user.id).picture
    assert_equal "RIFF", stored.byteslice(0, 4)
    assert_not_includes stored.b, "<script>".b
    assert_not_includes stored.b, "EXIF".b
  end

  test "analytics counts only: a fetch event with no name, id or url" do
    user = slack_player
    refresh(user)

    event = AnalyticsEvent.find_by(name: "slack_profile_fetched")
    assert_equal({ "picture" => true }, event&.props) if event
  end

  test "a player who turned the choice off is untouched: no request" do
    user = slack_player("p2", use_slack: false)
    outcome, network = refresh(user)

    assert_equal :skipped, outcome.status
    assert_empty network.requests
    assert_not SlackProfile.find_by!(user_id: user.id).picture?
  end

  test "there is no opt-in: a player with a Slack id and no row yet is fetched, and the row is made on" do
    user = make_player("norow")
    user.update_columns(slack_id: "U0NOROW001")
    assert_nil SlackProfile.find_by(user_id: user.id)
    outcome, network = refresh(user)

    assert_equal :ok, outcome.status
    assert_equal 1, network.calls_to("slack.com").size
    row = SlackProfile.find_by!(user_id: user.id)
    assert row.use_name && row.use_picture && row.picture?
    assert_equal "Maya", row.display_name
  end

  test "eligibility needs a Slack id and the bot token, nothing about a profile switch" do
    user = make_player("elig")
    assert_not_respond_to user, :profile_visible?
    user.update_columns(slack_id: "U0ELIG0001")
    with_bot_token { assert SlackProfiles.eligible?(user) }
    with_env("SLACK_BOT_TOKEN" => nil) { assert_not SlackProfiles.eligible?(user) }
    user.update_columns(slack_id: nil)
    with_bot_token { assert_not SlackProfiles.eligible?(user) }
    user.update_columns(slack_id: "not a slack id")
    with_bot_token { assert_not SlackProfiles.eligible?(user) }
  end

  test "a simulated player (no Slack id) is never fetched" do
    sim = make_player("simplayer")
    sim.update_columns(slack_id: nil, hca_uid: "sim!77")
    outcome, network = refresh(sim)
    assert_equal :skipped, outcome.status
    assert_empty network.requests
    assert_not_includes SlackProfiles.due_scope.pluck(:id), sim.id
  end

  test "no Slack id or no token means no request" do
    user = slack_player
    user.update_columns(slack_id: nil)
    _, network = refresh(user)
    assert_empty network.requests

    user.update_columns(slack_id: "U0PLAYER01")
    outcome = nil
    with_env("SLACK_BOT_TOKEN" => nil) { with_network(slack_router) { |seen| outcome = SlackProfiles::Refresh.call(user); assert_empty seen.requests } }
    assert_equal :skipped, outcome.status
  end

  test "once per 24 hours: a second call the same day makes no request, the next day it does" do
    user = slack_player
    now = Time.utc(2026, 11, 26, 12)
    refresh(user, now: now)
    outcome, network = refresh(user, now: now + 23.hours)
    assert_equal :skipped, outcome.status
    assert_empty network.requests

    outcome, network = refresh(user, now: now + 25.hours)
    assert_equal :ok, outcome.status
    assert_equal 1, network.calls_to("slack.com").size
  end

  test "missing_scope degrades to the generated avatar, logs one clear line, and shows in the admin status; no retry storm" do
    user = slack_player
    outcome = nil
    logs = capture_logs { outcome, = refresh(user, slack_router(info: slack_error("missing_scope"))) }

    assert_equal :missing_scope, outcome.status
    profile = SlackProfile.find_by!(user_id: user.id)
    assert_equal "missing_scope", profile.status
    assert_not profile.picture?
    assert_nil profile.display_name
    assert_includes logs, "users:read"
    assert_includes logs, "Players keep their generated avatars"
    assert_not_includes logs, TOKEN
    assert_operator profile.next_attempt_at, :>, 30.minutes.from_now
    assert_equal "Maya", user.reload.profile_name, "the profile name is left alone"

    other = slack_player("p3")
    _, network = refresh(other)
    assert_empty network.requests, "the whole app is held off for a while after a setup error"
  end

  test "ratelimited: honours Retry-After, holds every caller, and retries after it" do
    user = slack_player
    now = Time.utc(2026, 11, 26, 12)
    outcome, = refresh(user, slack_router(info: StreamResponse.new(429, "", "retry-after" => "42")), now: now)

    assert_equal :ratelimited, outcome.status
    assert_equal 43, outcome.retry_in
    profile = SlackProfile.find_by!(user_id: user.id)
    assert_equal "ratelimited", profile.status
    assert_in_delta (now + 42).to_f, profile.next_attempt_at.to_f, 1

    other = slack_player("p3")
    outcome, network = refresh(other, now: now + 5)
    assert_equal :waiting, outcome.status
    assert_empty network.requests

    outcome, = refresh(user, now: now + 43)
    assert_equal :ok, outcome.status
  end

  test "a rate limit that comes in a JSON body is honoured too" do
    user = slack_player
    outcome, = refresh(user, slack_router(info: StreamResponse.new(200, JSON.generate(ok: false, error: "ratelimited"), "retry-after" => "7")))
    assert_equal :ratelimited, outcome.status
    assert_equal 8, outcome.retry_in
  end

  test "our own limit holds back a burst without calling Slack" do
    now = Time.utc(2026, 11, 26, 12, 0, 10)
    SlackProfiles::Gate::PER_MINUTE.times { assert_equal 0, SlackProfiles::Gate.wait(now: now) }
    assert_operator SlackProfiles::Gate.wait(now: now), :>, 0
    assert_equal 0, SlackProfiles::Gate.wait(now: now + 60)
  end

  test "network errors back off and are retried; the name and picture stay as they were" do
    user = slack_player
    refresh(user)
    profile = SlackProfile.find_by!(user_id: user.id)
    profile.update_columns(fetched_at: 2.days.ago, display_name: "Maya")
    sha = profile.picture_sha256

    outcome = nil
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*, **, &_| raise Net::OpenTimeout }
    begin
      with_bot_token { outcome = SlackProfiles::Refresh.call(user) }
    ensure
      Net::HTTP.define_singleton_method(:start, original)
    end

    assert_equal :error, outcome.status
    profile.reload
    assert_equal "error", profile.status
    assert_equal 1, profile.failure_count
    assert_equal sha, profile.picture_sha256
    assert_equal "Maya", profile.display_name
    assert_operator profile.next_attempt_at, :>, Time.current
  end

  test "a person who is not in the workspace (or is a bot) is marked not_found and left alone" do
    user = slack_player
    outcome, = refresh(user, slack_router(info: slack_error("user_not_found")))
    assert_equal :not_found, outcome.status
    assert_equal "not_found", SlackProfile.find_by!(user_id: user.id).status

    other = slack_player("p3")
    bot = StreamResponse.new(200, JSON.generate(ok: true, user: { id: "U0BOT", is_bot: true, profile: {} }))
    outcome, = refresh(other, slack_router(info: bot))
    assert_equal :not_found, outcome.status
  end

  test "Slack's default picture (not custom) stores no picture and keeps the generated avatar" do
    user = slack_player
    outcome, network = refresh(user, slack_router(info: slack_ok(custom: false)))

    assert_equal :ok, outcome.status
    profile = SlackProfile.find_by!(user_id: user.id)
    assert_equal "no_picture", profile.status
    assert_not profile.picture?
    assert_equal "Maya", profile.display_name
    assert_equal [ "slack.com" ], network.hosts.uniq
  end

  test "a picture on a host that is not Slack's is never fetched (SSRF guard), and the rest still works" do
    [ "https://evil.example.com/a.png", "https://slack.com.evil.example/a.png", "https://evilslack.com/a.png", "http://avatars.slack-edge.com/a.png",
      "https://169.254.169.254/latest/meta-data", "https://localhost/a.png", "https://user@avatars.slack-edge.com/a.png",
      "https://avatars.slack-edge.com:8443/a.png", "file:///etc/passwd", "//avatars.slack-edge.com/a.png" ].each_with_index do |url, index|
      user = slack_player("h#{index}")
      user.update_columns(slack_id: "U0#{SecureRandom.hex(3).upcase}")
      outcome, network = refresh(user, slack_router(info: slack_ok(image: url)))

      assert_equal :ok, outcome.status, url
      assert_equal [ "slack.com" ], network.hosts.uniq, "must not connect to the host in #{url}"
      assert_not SlackProfile.find_by!(user_id: user.id).picture?, url
      assert_equal "Maya", SlackProfile.find_by!(user_id: user.id).display_name
    end
  end

  test "a redirect to another host is refused; a redirect inside Slack's hosts is followed" do
    user = slack_player
    redirect = StreamResponse.new(302, "", "location" => "https://evil.example.com/a.png")
    _, network = refresh(user, slack_router(picture: redirect))
    assert_equal [ "slack.com", "avatars.slack-edge.com" ], network.hosts
    assert_not SlackProfile.find_by!(user_id: user.id).picture?

    other = slack_player("p3")
    router = lambda do |host, request|
      next slack_ok if host == "slack.com"
      next StreamResponse.new(302, "", "location" => "https://files.slack.com/x.png") if host == "avatars.slack-edge.com"

      StreamResponse.new(200, picture_bytes(:png))
    end
    _, network = refresh(other, router)
    assert_equal [ "slack.com", "avatars.slack-edge.com", "files.slack.com" ], network.hosts
    assert SlackProfile.find_by!(user_id: other.id).picture?
  end

  test "an oversize download and a decompression bomb are rejected, the name is still kept" do
    user = slack_player
    huge = StreamResponse.new(200, "x" * (SlackProfiles::Download::MAX_BYTES + 10))
    refresh(user, slack_router(picture: huge))
    profile = SlackProfile.find_by!(user_id: user.id)
    assert_not profile.picture?
    assert_equal "Maya", profile.display_name

    declared = StreamResponse.new(200, "tiny", "content-length" => (SlackProfiles::Download::MAX_BYTES + 1).to_s)
    other = slack_player("p3")
    refresh(other, slack_router(picture: declared))
    assert_not SlackProfile.find_by!(user_id: other.id).picture?

    bomb = slack_player("p4")
    big = Vips::Image.black(5000, 5000).pngsave_buffer
    refresh(bomb, slack_router(picture: StreamResponse.new(200, big)))
    assert_not SlackProfile.find_by!(user_id: bomb.id).picture?
  end

  test "bytes that are not a picture (an SVG, HTML, a truncated PNG, a lie in the content type) are rejected" do
    [ '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>', "<html></html>", picture_bytes(:png).byteslice(0, 60), "" ].each_with_index do |body, index|
      user = slack_player("q#{index}")
      user.update_columns(slack_id: "U0Q#{index}ABCDE")
      refresh(user, slack_router(picture: StreamResponse.new(200, body, "content-type" => "image/png")))
      assert_not SlackProfile.find_by!(user_id: user.id).picture?, body.first(20).inspect
    end
  end

  test "the name is sanitised: control characters, bidi overrides, zero-width characters and over-long names" do
    {
      "Ma‮ya\u0000" => "Maya",
      "Ma​ya⁦" => "Maya",
      "  Maya \n\t  Kai " => "Maya Kai",
      ("x" * 80) => "x" * 30,
      "‮​" => nil
    }.each do |raw, expected|
      assert_equal expected.to_s, SlackProfiles::Sanitizer.display_name(raw).to_s, raw.inspect
    end
    assert_equal "<b>Maya</b>", SlackProfiles::Sanitizer.display_name("<b>Maya</b>"), "markup is escaped on output, not stripped here"
  end

  test "the profile name rules still apply to the names the simulator makes from a Slack name" do
    assert_equal "Maya Kai", SlackProfiles::Sanitizer.profile_name("Maya Kai")
    assert_equal "Maya 3", SlackProfiles::Sanitizer.profile_name("Maya <3 \u{1F600}")
    assert_nil SlackProfiles::Sanitizer.profile_name("\u{1F600}\u{1F600}")
    assert_not_nil PublicProfile::NAME_FORMAT.match(SlackProfiles::Sanitizer.profile_name("evil.com"))
  end

  test "Slack's real_name is never read: a blank display name stores no name at all" do
    [ "", "   ", nil ].each do |blank|
      user = slack_player(name: nil)
      SlackProfile.where(user_id: user.id).update_all(display_name: "Old Name")
      refresh(user, slack_router(info: slack_ok(name: blank, real_name: "Maya Real Name")))
      row = SlackProfile.find_by!(user_id: user.id)
      assert_nil row.display_name, "display_name #{blank.inspect}: the stored name is cleared, not replaced by the real name"
      assert_equal PublicProfile.handle_for(user.public_slug), user.reload.public_name
      user.destroy!
    end
    result = with_network(->(*) { slack_ok(name: "", real_name: "Maya Real Name") }) { SlackProfiles::Client.new(token: TOKEN).user_info(USER_SLACK_ID) }
    assert result.ok?
    assert_nil result.name
  end

  test "the Slack name is kept on the row, never copied over the display name a player chose" do
    user = slack_player(name: "Chosen")
    refresh(user, slack_router(info: slack_ok(name: "Maya K")))
    assert_equal "Chosen", user.reload.profile_name
    assert_equal "Maya K", SlackProfile.find_by!(user_id: user.id).display_name
    assert_equal "Chosen", user.public_name
    user.update!(profile_name: nil)
    assert_equal "Maya K", user.public_name
  end

  test "someone who typed their own name keeps it, and still gets the Slack picture" do
    user = slack_player(name: "My Own Name")
    refresh(user)

    assert_equal "My Own Name", user.reload.profile_name
    assert_equal "My Own Name", user.public_name
    assert SlackProfile.find_by!(user_id: user.id).picture?
  end

  test "turning the choice off deletes the copy, and turning it on fetches again" do
    user = slack_player
    refresh(user)
    SlackProfiles::Choice.set(user, use_slack: false)
    profile = SlackProfile.find_by!(user_id: user.id)
    assert_not profile.picture?
    assert_nil profile.display_name
    assert_not SlackProfiles::Choice.use_slack?(user)
    _, network = refresh(user)
    assert_empty network.requests

    SlackProfiles::Choice.set(user, use_slack: true)
    refresh(user)
    assert SlackProfile.find_by!(user_id: user.id).picture?
  end

  test "the user's deletion removes the row (ON DELETE CASCADE)" do
    user = slack_player
    refresh(user)
    assert_difference "SlackProfile.count", -1 do
      Privacy::Deleter.new(Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: user.hca_uid)).call(dry_run: false)
    end
  end

  test "the client keeps only the allowlisted error codes, never a response body or the token" do
    client = SlackProfiles::Client.new(token: TOKEN)
    result = nil
    with_network(slack_router(info: StreamResponse.new(200, JSON.generate(ok: false, error: "Bad #{TOKEN} here")))) { result = client.user_info("U0PLAYER01") }
    assert_equal "unknown_error", result.error_code
    assert_not_includes result.to_h.to_s, TOKEN
    assert_raises(ArgumentError) { SlackProfiles::Client.new(endpoint: "http://slack.com/api/users.info") }
    assert_equal "not_found", client.user_info("not a slack id").error_code
  end
end
