require "test_helper"
require "rake"
require_relative "../../support/hackatime_helper"

# The live source plugged into the hours ledger: source selection, Hours::Sync end to end against the local fake
# provider, and the hackatime:sync rake task.
module Hackatime
  class HoursWiringTest < ActiveSupport::TestCase
    include HackatimeHelper

    NOW = Time.utc(2026, 11, 11, 12, 0, 0)
    PROJECTS = "/api/v1/authenticated/projects".freeze

    setup do
      Rails.application.load_tasks unless Rake::Task.task_defined?("hackatime:sync")
      @fake = start_fake_hackatime
      @user = users(:onboarded)
      @user.update!(time_zone: "UTC")
      travel_to NOW
    end

    teardown do
      travel_back
      stop_fake_hackatime
    end

    def serve(projects_by_day)
      @fake.on("GET", PROJECTS) { |req| [ 200, { "projects" => projects_by_day.fetch(req.query["start_date"][0, 10], []) } ] }
    end

    # Runs the task as configured for live Hackatime unless another hours source is given.
    def run_task(*args, hours_source: "http")
      task = Rake::Task["hackatime:sync"]
      task.reenable
      with_env("HOURS_SOURCE", hours_source) { capture_io { task.invoke(*args) }.first }
    end

    def with_env(name, value)
      original = ENV[name]
      ENV[name] = value
      yield
    ensure
      ENV[name] = original
    end

    test "the source is chosen by config and the HOURS_SOURCE variable" do
      assert_instance_of NullSource, Hackatime.source
      with_env("HOURS_SOURCE", "http") { assert_instance_of HttpSource, Hackatime.source }
      with_env("HOURS_SOURCE", "null") { assert_instance_of NullSource, Hackatime.source }
      with_env("HOURS_SOURCE", "carrier-pigeon") { assert_raises(ArgumentError) { Hackatime.source } }
    end

    test "HttpSource is a Hackatime::Source and treats nil bounds as the recent window ending today" do
      source = HttpSource.new
      assert_kind_of Source, source
      connect_hackatime(@user)
      serve({})

      source.daily_seconds(user: @user)

      starts = @fake.requests_for("GET", PROJECTS).map { |r| r.query["start_date"][0, 10] }
      assert_equal HttpSource::MAX_DAYS, starts.size
      assert_equal "2026-11-11", starts.last
    end

    test "Hours::Sync credits live Hackatime time once, and a repeat changes nothing" do
      connect_hackatime(@user)
      serve("2026-11-11" => [ { "name" => "battletown", "total_seconds" => 3_600 } ],
            "2026-11-10" => [ { "name" => "battletown", "total_seconds" => 1_200 }, { "name" => "dots", "total_seconds" => 600 } ])

      first = Hours::Sync.call(@user, source: HttpSource.new)
      assert_equal 5_400, first.credited_seconds
      assert_equal 3, first.credited_days

      again = Hours::Sync.call(@user, source: HttpSource.new)
      assert_equal 0, again.credited_seconds
      assert_equal 3, again.unchanged_days
      assert_equal 3, HourEntry.where(user_id: @user.id, source: "hackatime").count
    end

    test "hackatime:sync[all] syncs linked users, skips those needing a reconnect, and prints counts only" do
      connect_hackatime(@user)
      connect_hackatime(users(:new_user), uid: "77", needs_reconnect: true)
      serve("2026-11-11" => [ { "name" => "battletown", "total_seconds" => 900 } ])

      out = run_task("all")

      assert_match(/hackatime:sync users=1 needs_reconnect=0 retry_later=0 credited_seconds=900 credited_days=1/, out)
      assert_not_includes out, SECRET_TOKEN
      assert_not_includes out, @user.display_name.to_s
    end

    test "hackatime:sync counts a rejected token and a rate limit without failing" do
      connection = connect_hackatime(@user)
      @fake.on("GET", PROJECTS) { |_req| [ 401, {} ] }
      assert_match(/users=0 needs_reconnect=1 retry_later=0/, run_task("all"))
      assert connection.reload.needs_reconnect?

      connection.update!(needs_reconnect: false)
      @fake.on("GET", PROJECTS) { |_req| [ 429, {} ] }
      assert_match(/users=0 needs_reconnect=0 retry_later=1/, run_task(@user.id.to_s))
    end

    test "hackatime:sync does nothing, and never calls Hackatime, unless the hours source is http" do
      connect_hackatime(@user)
      serve("2026-11-11" => [ { "name" => "battletown", "total_seconds" => 900 } ])

      [ nil, "null" ].each do |hours_source|
        assert_equal "hackatime:sync skipped: the hours source is null, not http (set HOURS_SOURCE=http to sync)\n",
                     run_task("all", hours_source: hours_source)
      end
      assert_empty @fake.requests_for("GET", PROJECTS)
      assert_equal 0, HourEntry.where(user_id: @user.id).count

      task = Rake::Task["hackatime:sync"]
      task.reenable
      with_env("HOURS_SOURCE", "carrier-pigeon") { assert_raises(SystemExit) { capture_io { task.invoke("all") } } }
      assert_empty @fake.requests_for("GET", PROJECTS)
    end

    test "hackatime:sync needs a target" do
      task = Rake::Task["hackatime:sync"]
      task.reenable
      assert_raises(SystemExit) { capture_io { task.invoke } }
    end
  end
end
