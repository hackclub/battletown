require "test_helper"
require_relative "../../support/hackatime_helper"

module Hackatime
  class HttpSourceTest < ActiveSupport::TestCase
    include HackatimeHelper

    PROJECTS = "/api/v1/authenticated/projects".freeze

    setup do
      @fake = start_fake_hackatime
      @user = users(:onboarded)
      @source = HttpSource.new
    end

    teardown { stop_fake_hackatime }

    def windows = @fake.requests_for("GET", PROJECTS).map { |r| [ r.query["start_date"], r.query["end_date"] ] }

    test "maps each local day and project to a row, and records the sync" do
      @user.update!(time_zone: "UTC")
      connection = connect_hackatime(@user)
      @fake.on("GET", PROJECTS) do |req|
        day = req.query["start_date"][0, 10]
        [ 200, { "projects" => day == "2026-11-03" ? [ { "name" => "battletown", "total_seconds" => 3600.9 }, { "name" => "dots", "total_seconds" => 0 } ] : [] } ]
      end

      rows = @source.daily_seconds(user: @user, from: Date.new(2026, 11, 2), to: Date.new(2026, 11, 4))

      assert_equal [ DaySeconds.new(date: Date.new(2026, 11, 3), seconds: 3600, project: "battletown") ], rows
      assert_equal 3, windows.size
      request = @fake.requests_for("GET", PROJECTS).first
      assert_equal "true", request.query["include_archived"]
      assert_equal "Bearer #{SECRET_TOKEN}", request.headers["authorization"]
      assert_not_nil connection.reload.last_synced_at
    end

    test "each day is a window between the user's own local midnights" do
      @user.update!(time_zone: "Tokyo")
      connect_hackatime(@user)
      @fake.on("GET", PROJECTS) { |_req| [ 200, { "projects" => [] } ] }

      @source.daily_seconds(user: @user, from: Date.new(2026, 11, 3), to: Date.new(2026, 11, 3))

      assert_equal [ [ "2026-11-03T00:00:00.000+09:00", "2026-11-03T23:59:59.999+09:00" ] ], windows
    end

    test "a day that is 25 hours long (DST ends) keeps its real bounds" do
      @user.update!(time_zone: "Eastern Time (US & Canada)")
      connect_hackatime(@user)
      @fake.on("GET", PROJECTS) { |_req| [ 200, { "projects" => [] } ] }

      @source.daily_seconds(user: @user, from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 1))

      assert_equal [ [ "2026-11-01T00:00:00.000-04:00", "2026-11-01T23:59:59.999-05:00" ] ], windows
    end

    test "a day that is 23 hours long (DST starts) keeps its real bounds" do
      @user.update!(time_zone: "Eastern Time (US & Canada)")
      connect_hackatime(@user)
      @fake.on("GET", PROJECTS) { |_req| [ 200, { "projects" => [] } ] }

      @source.daily_seconds(user: @user, from: Date.new(2026, 3, 8), to: Date.new(2026, 3, 8))

      assert_equal [ [ "2026-03-08T00:00:00.000-05:00", "2026-03-08T23:59:59.999-04:00" ] ], windows
    end

    test "what day it is follows the user's zone: a day that has not started there yet is not asked for" do
      @user.update!(time_zone: "Eastern Time (US & Canada)")
      connect_hackatime(@user)
      @fake.on("GET", PROJECTS) { |_req| [ 200, { "projects" => [] } ] }

      # 02:00 UTC on the 5th is still the evening of the 4th in New York.
      travel_to Time.utc(2026, 11, 5, 2, 0, 0) do
        @source.daily_seconds(user: @user, from: Date.new(2026, 11, 3), to: Date.new(2026, 11, 5))
      end

      assert_equal %w[2026-11-03 2026-11-04], windows.map { |start, _| start[0, 10] }
    end

    test "nonsense seconds are clamped to a day and junk rows are skipped" do
      @user.update!(time_zone: "UTC")
      connect_hackatime(@user)
      @fake.on("GET", PROJECTS) do |_req|
        [ 200, { "projects" => [ { "name" => "huge", "total_seconds" => 10_000_000 }, { "name" => "", "total_seconds" => 5 },
                                  { "name" => "neg", "total_seconds" => -4 }, "junk", nil ] } ]
      end

      rows = @source.daily_seconds(user: @user, from: Date.new(2026, 11, 3), to: Date.new(2026, 11, 3))

      assert_equal [ [ "huge", 25 * 3600 ] ], rows.map { |row| [ row.project, row.seconds ] }
    end

    test "no connection, or one that needs reconnecting, means no rows and no requests" do
      assert_empty @source.daily_seconds(user: @user, from: Date.new(2026, 11, 3), to: Date.new(2026, 11, 3))
      connect_hackatime(@user, needs_reconnect: true)
      assert_empty @source.daily_seconds(user: @user, from: Date.new(2026, 11, 3), to: Date.new(2026, 11, 3))
      assert_empty @fake.requests
    end

    test "a rate limit surfaces as a retryable error and does not record a sync" do
      connection = connect_hackatime(@user)
      @fake.on("GET", PROJECTS) { |_req| [ 429, { "error" => "slow down" } ] }

      assert_raises(Client::RetryableError) { @source.daily_seconds(user: @user, from: Date.new(2026, 11, 3), to: Date.new(2026, 11, 3)) }
      assert_nil connection.reload.last_synced_at
      assert_not connection.needs_reconnect?
    end

    test "ranges longer than the cap are refused" do
      connect_hackatime(@user)
      assert_raises(ArgumentError) { @source.daily_seconds(user: @user, from: Date.new(2026, 1, 1), to: Date.new(2026, 6, 1)) }
    end

    test "a user without a time zone is treated as UTC" do
      @user.update_columns(time_zone: nil)
      connect_hackatime(@user)
      @fake.on("GET", PROJECTS) { |_req| [ 200, { "projects" => [] } ] }

      @source.daily_seconds(user: @user.reload, from: Date.new(2026, 11, 3), to: Date.new(2026, 11, 3))

      assert_equal [ [ "2026-11-03T00:00:00.000Z", "2026-11-03T23:59:59.999Z" ] ], windows
    end
  end
end
