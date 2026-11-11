require "test_helper"
require "rake"
require "yaml"
require_relative "../../../support/notifications_helper"

class Notifications::Slack::CheckTest < ActiveSupport::TestCase
  include NotificationsHelper

  OK_BODY = { ok: true, team: "Hack Club", user: "battletown", bot_id: "B0TEST", team_id: "T0TEST", user_id: "U0BOT" }.freeze
  MANIFEST = Rails.root.join("config/slack/manifest.yml")

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("slack:check")
  end

  def check(response: nil, error: nil, token: TOKEN)
    report = nil
    seen = nil
    stub_http(response: response, error: error) do |s|
      report = Notifications::Slack::Check.new(token: token).call
      seen = s
    end
    [ report, seen ]
  end

  def scoped(scopes, body = OK_BODY)
    json_response(body, headers: { "x-oauth-scopes" => scopes })
  end

  def run_task(name, *args)
    task = Rake::Task[name]
    task.reenable
    out = err = nil
    status = nil
    out, err = capture_io do
      task.invoke(*args)
    rescue SystemExit => e
      status = e.status
    end
    [ out, err, status ]
  end

  test "asks auth.test over HTTPS with a bearer token and 5 second timeouts" do
    report, seen = check(response: scoped("chat:write"))
    assert report.ok?
    start = seen[:starts].sole
    assert_equal "slack.com", start[:host]
    assert_equal true, start[:options][:use_ssl]
    assert_equal [ 5, 5, 5 ], start[:options].values_at(:open_timeout, :read_timeout, :write_timeout)
    request = seen[:http].requests.sole
    assert_equal "/api/auth.test", request.path
    assert_equal "Bearer #{TOKEN}", request["Authorization"]
  end

  test "refuses a non-HTTPS endpoint" do
    assert_raises(ArgumentError) { Notifications::Slack::Check.new(token: TOKEN, endpoint: "http://slack.com/api/auth.test") }
  end

  test "reports the workspace, bot name and scopes and never the token" do
    report, = check(response: scoped("chat:write"))
    assert_equal "Hack Club", report.team
    assert_equal "battletown", report.user
    assert_equal [ "chat:write" ], report.scopes
    assert_empty report.problems
    assert_not_includes report.to_h.to_s, TOKEN
  end

  test "extra scopes are a problem" do
    report, = check(response: scoped("chat:write, users:read.email,im:write"))
    assert_not report.ok?
    assert_equal [ "chat:write", "im:write", "users:read.email" ], report.scopes
    assert_match(/Unexpected scopes: im:write, users:read\.email/, report.problems.sole)
  end

  test "a missing chat:write scope is a problem" do
    report, = check(response: scoped("commands"))
    assert_not report.ok?
    assert_equal 2, report.problems.size
    assert(report.problems.any? { |problem| problem.start_with?("Missing scopes: chat:write") })
  end

  test "no scopes header still passes when Slack accepts a bot token" do
    report, = check(response: json_response(OK_BODY))
    assert report.ok?
    assert_nil report.scopes
  end

  test "a token that is not a bot token is a problem" do
    report, = check(response: scoped("chat:write", OK_BODY.except(:bot_id)))
    assert_not report.ok?
    assert_match(/not a bot token/, report.problems.sole)
  end

  test "a missing token makes no request" do
    with_env("SLACK_BOT_TOKEN" => nil) do
      report, seen = check(response: scoped("chat:write"), token: nil)
      assert_not report.ok?
      assert_match(/SLACK_BOT_TOKEN is not set/, report.problems.sole)
      assert_empty seen[:starts]
    end
  end

  test "a rejected token shows only an allowlisted Slack error code" do
    report, = check(response: json_response({ ok: false, error: "invalid_auth" }))
    assert_match(/error: invalid_auth/, report.problems.sole)
    report, = check(response: json_response({ ok: false, error: "Bad #{TOKEN} here" }))
    assert_match(/error: unknown_error/, report.problems.sole)
    assert_not_includes report.problems.sole, TOKEN
  end

  test "http errors, unreadable bodies and network errors are reported without details" do
    assert_match(/HTTP status 503/, check(response: json_response("", code: "503")).first.problems.sole)
    assert_match(/could not be read/, check(response: json_response("<html>")).first.problems.sole)
    assert_match(/network error/, check(error: Net::OpenTimeout.new("boom #{TOKEN}")).first.problems.sole)
  end

  test "unprintable characters and long names from Slack are cleaned" do
    report, = check(response: scoped("chat:write", OK_BODY.merge(team: "Hack\e[31m Club" + ("x" * 200))))
    assert_not_includes report.team, "\e"
    assert_operator report.team.length, :<=, 80
  end

  test "slack:check prints workspace, bot and scopes without the token and exits 0" do
    with_env("SLACK_BOT_TOKEN" => TOKEN) do
      stub_http(response: scoped("chat:write")) do
        out, err, status = run_task("slack:check")
        assert_nil status
        assert_includes out, 'workspace="Hack Club" bot="battletown" scopes=chat:write'
        assert_includes out, "slack:check ok"
        assert_not_includes out + err, TOKEN
      end
    end
  end

  test "slack:check exits 1 with a clear message for extra scopes or a missing token" do
    with_env("SLACK_BOT_TOKEN" => TOKEN) do
      stub_http(response: scoped("chat:write,channels:history")) do
        _out, err, status = run_task("slack:check")
        assert_equal 1, status
        assert_includes err, "Unexpected scopes: channels:history"
        assert_not_includes err, TOKEN
      end
    end
    with_env("SLACK_BOT_TOKEN" => nil) do
      _out, err, status = run_task("slack:check")
      assert_equal 1, status
      assert_includes err, "SLACK_BOT_TOKEN is not set"
    end
  end

  test "slack:self_test sends exactly one DM to the given id" do
    with_env("SLACK_BOT_TOKEN" => TOKEN) do
      stub_http(response: json_response({ ok: true })) do |seen|
        out, _err, status = run_task("slack:self_test", "U054VC2KM9P")
        assert_nil status
        assert_includes out, "sent 1 message"
        assert_equal "U054VC2KM9P", JSON.parse(seen[:http].requests.sole.body)["channel"]
      end
    end
  end

  test "slack:self_test refuses to run without a token or a valid Slack user id" do
    with_env("SLACK_BOT_TOKEN" => nil) do
      stub_http(response: json_response({ ok: true })) do |seen|
        _out, err, status = run_task("slack:self_test", "U054VC2KM9P")
        assert_equal 1, status
        assert_includes err, "SLACK_BOT_TOKEN is not set"
        assert_empty seen[:starts]
      end
    end
    with_env("SLACK_BOT_TOKEN" => TOKEN) do
      stub_http(response: json_response({ ok: true })) do |seen|
        [ nil, "", "general", "#general", "u054vc2km9p" ].each do |bad|
          _out, err, status = run_task("slack:self_test", *bad)
          assert_equal 1, status, bad.inspect
          assert_includes err, "needs a Slack user id"
        end
        assert_empty seen[:starts]
      end
    end
  end

  test "slack:self_test reports a failure code and exits 1" do
    with_env("SLACK_BOT_TOKEN" => TOKEN) do
      stub_http(response: json_response({ ok: false, error: "user_not_found" })) do
        _out, err, status = run_task("slack:self_test", "U0NOBODY1")
        assert_equal 1, status
        assert_includes err, "failed: user_not_found"
      end
    end
  end

  test "the manifest asks for chat:write only and nothing that needs a server" do
    manifest = YAML.safe_load_file(MANIFEST)
    assert_equal Notifications::Slack::Check::EXPECTED_SCOPES, manifest.dig("oauth_config", "scopes", "bot")
    assert_nil manifest.dig("oauth_config", "scopes", "user")
    assert_equal "Battletown", manifest.dig("display_information", "name")
    assert_equal "Battletown", manifest.dig("features", "bot_user", "display_name")
    assert_equal false, manifest.dig("features", "bot_user", "always_online")
    assert_equal({ "org_deploy_enabled" => false, "socket_mode_enabled" => false, "token_rotation_enabled" => false },
                 manifest["settings"])
    assert_equal %w[bot_user], manifest["features"].keys
    assert_operator manifest.dig("display_information", "description").length, :<=, 140
  end
end
