require "test_helper"
require_relative "../../support/hackatime_helper"
require_relative "../../support/ships_test_support"

# The Hackatime project names offered on the link page: the person's own, only usable ones, never logged.
class Hackatime::ProjectNamesTest < ActiveSupport::TestCase
  include HackatimeHelper
  include ShipsTestSupport

  setup { @user = users(:onboarded) }
  teardown { stop_fake_hackatime }

  def serve(body, status: 200)
    fake = start_fake_hackatime
    fake.on("GET", "/api/v1/authenticated/projects") { |_| [ status, body ] }
    fake
  end

  test "no connection, or one that needs reconnecting, is not ok and asks Hackatime nothing" do
    fake = serve({ "projects" => [] })
    assert_not Hackatime::ProjectNames.for(@user).ok?

    connect_hackatime(@user, needs_reconnect: true)
    result = Hackatime::ProjectNames.for(@user.reload)
    assert_not result.ok?
    assert_equal [], result.names
    assert_empty fake.requests
  end

  test "names come back sorted and de-duplicated, without unlinkable names or ones already linked, and blanks" do
    make_project(@user, hackatime: "mine")
    connect_hackatime(@user)
    serve({ "projects" => [ { "name" => "zeta" }, { "name" => "Alpha" }, { "name" => "alpha" }, { "name" => "zeta" }, { "name" => "mine" },
                            { "name" => "bad<name>" }, { "name" => "" }, { "name" => "x" * 121 }, "junk", { "total_seconds" => 5 } ] })
    result = Hackatime::ProjectNames.for(@user.reload)
    assert result.ok?
    assert_equal %w[Alpha alpha zeta], result.names
  end

  test "it asks for the last year with archived projects, as the signed-in person only" do
    connect_hackatime(@user)
    fake = serve({ "projects" => [] })
    Hackatime::ProjectNames.for(@user.reload)
    request = fake.requests_for("GET", "/api/v1/authenticated/projects").sole
    assert_equal "true", request.query["include_archived"]
    assert_in_delta 365, (Time.zone.parse(request.query["end_date"]) - Time.zone.parse(request.query["start_date"])) / 86_400.0, 1.1
    assert_equal "Bearer #{SECRET_TOKEN}", request.headers["authorization"]
  end

  test "rejected credentials, a server error or garbage are not ok, and a rejected token marks the connection" do
    connect_hackatime(@user)
    serve({ "error" => "unauthorized" }, status: 401)
    assert_not Hackatime::ProjectNames.for(@user.reload).ok?
    assert @user.reload.hackatime_connection.needs_reconnect?
    stop_fake_hackatime

    @user.hackatime_connection.update!(needs_reconnect: false)
    serve({ "error" => "boom" }, status: 500)
    assert_not Hackatime::ProjectNames.for(@user.reload).ok?
    stop_fake_hackatime

    serve("<html>not json</html>")
    assert_not Hackatime::ProjectNames.for(@user.reload).ok?
  end

  test "the names are never logged" do
    connect_hackatime(@user)
    serve({ "projects" => [ { "name" => "probe-secret-project" } ] })
    logged = capture_logs { Hackatime::ProjectNames.for(@user.reload) }
    assert_not_includes logged, "probe-secret-project"
  end

  test "the window starts at the project time cutoff when that is later than a year ago, in the person's own zone" do
    @user.update_columns(time_zone: "America/New_York")
    connect_hackatime(@user)
    fake = serve({ "projects" => [] })
    cutoff = Ships::Config.current.with(project_time_from: Date.current - 3)
    original = Ships::Config.instance_variable_get(:@current)
    Ships::Config.instance_variable_set(:@current, cutoff)
    Hackatime::ProjectNames.for(@user.reload)
    start = Time.iso8601(fake.requests_for("GET", "/api/v1/authenticated/projects").sole.query["start_date"])
    assert_equal (Date.current - 3).iso8601, start.in_time_zone("America/New_York").to_date.iso8601
    assert_equal 0, start.in_time_zone("America/New_York").hour
  ensure
    Ships::Config.instance_variable_set(:@current, original)
  end
end
