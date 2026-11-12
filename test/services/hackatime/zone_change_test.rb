require "test_helper"
require_relative "../../support/hackatime_helper"

# Changing time zone, or linking one Hackatime account to a second Battletown account, must never credit the same
# coded instant twice (docs/HACKATIME.md, "Days and time zones"). The fake Hackatime here answers like the real one:
# the seconds of coding that fall inside the requested window, so the tests reason about real instants.
module Hackatime
  class ZoneChangeTest < ActiveSupport::TestCase
    include HackatimeHelper

    PROJECTS = "/api/v1/authenticated/projects".freeze

    setup do
      @fake = start_fake_hackatime
      @user = users(:onboarded)
      @coding = []
      @fake.on("GET", PROJECTS) do |req|
        from = Time.iso8601(req.query["start_date"])
        to = Time.iso8601(req.query["end_date"]) + HttpSource::END_MARGIN # the real window is inclusive
        seconds = @coding.sum { |starts, ends| [ [ ends, to ].min - [ starts, from ].max, 0 ].max }
        [ 200, { "projects" => seconds.positive? ? [ { "name" => "battletown", "total_seconds" => seconds.to_f } ] : [] } ]
      end
    end

    teardown do
      travel_back
      stop_fake_hackatime
    end

    def code(starts, ends) = @coding << [ starts, ends ]

    def sync_at(now, user = @user)
      travel_to(now) { Hours::Sync.call(user.reload, source: HttpSource.new) }
    end

    def ledger(user = @user) = HourEntry.where(user_id: user.id).sum(:seconds)

    def utc(*args) = Time.utc(*args)

    test "moving from the date line's west side to Nuku'alofa does not credit the same two hours again" do
      @user.update!(time_zone: "International Date Line West")
      connect_hackatime(@user)
      code(utc(2026, 11, 11, 2), utc(2026, 11, 11, 4))

      sync_at utc(2026, 11, 11, 6)
      assert_equal 7_200, ledger
      assert_equal({ Date.new(2026, 11, 10) => 7_200 }, Hours::Totals.seconds_by_date(@user, ..Date.new(2026, 11, 30)))

      @user.update!(time_zone: "Nuku'alofa")
      sync_at utc(2026, 11, 11, 6, 30)
      sync_at utc(2026, 11, 11, 10)
      assert_equal 7_200, ledger

      # Time coded after the switch still counts, on the new zone's dates.
      code(utc(2026, 11, 11, 13), utc(2026, 11, 11, 14))
      sync_at utc(2026, 11, 11, 20)
      assert_equal 10_800, ledger
      assert_equal 3_600, Hours::Totals.seconds_for_date(@user, Date.new(2026, 11, 12))
    end

    test "time coded just before the switch, inside a date that is already synced, is not lost" do
      @user.update!(time_zone: "International Date Line West")
      connect_hackatime(@user)
      sync_at utc(2026, 11, 11, 6)

      @user.update!(time_zone: "Nuku'alofa")
      # 11:30 UTC is still the old zone's 10 November, which keeps its original window.
      code(utc(2026, 11, 11, 11, 30), utc(2026, 11, 11, 12, 30))
      sync_at utc(2026, 11, 11, 20)

      assert_equal 3_600, ledger
      assert_equal({ Date.new(2026, 11, 10) => 1_800, Date.new(2026, 11, 12) => 1_800 },
                   Hours::Totals.seconds_by_date(@user, ..Date.new(2026, 11, 30)))
    end

    test "a one hour move east does not count the overlapping hour twice" do
      @user.update!(time_zone: "London")
      connect_hackatime(@user)
      code(utc(2026, 11, 10, 22, 30), utc(2026, 11, 10, 23, 30))
      sync_at utc(2026, 11, 10, 23, 45)
      assert_equal 3_600, ledger

      @user.update!(time_zone: "Paris")
      code(utc(2026, 11, 11, 10), utc(2026, 11, 11, 11))
      sync_at utc(2026, 11, 11, 12)

      assert_equal 7_200, ledger
      assert_equal({ Date.new(2026, 11, 10) => 3_600, Date.new(2026, 11, 11) => 3_600 },
                   Hours::Totals.seconds_by_date(@user, ..Date.new(2026, 11, 30)))
    end

    test "a one hour move west loses nothing: the next date starts where the last synced one ended" do
      @user.update!(time_zone: "Paris")
      connect_hackatime(@user)
      sync_at utc(2026, 11, 11, 12)

      @user.update!(time_zone: "London")
      # Paris's 11 November ends at 23:00 UTC; London's 12 November starts at midnight UTC.
      code(utc(2026, 11, 11, 22, 30), utc(2026, 11, 12, 0, 30))
      sync_at utc(2026, 11, 12, 6)

      assert_equal 7_200, ledger
      assert_equal({ Date.new(2026, 11, 11) => 1_800, Date.new(2026, 11, 12) => 5_400 },
                   Hours::Totals.seconds_by_date(@user, ..Date.new(2026, 11, 30)))
    end

    test "the reverse extreme move (Nuku'alofa to the date line's west side) neither repeats nor drops time" do
      @user.update!(time_zone: "Nuku'alofa")
      connect_hackatime(@user)
      code(utc(2026, 11, 10, 20), utc(2026, 11, 10, 22))
      sync_at utc(2026, 11, 10, 23)
      assert_equal 7_200, ledger

      @user.update!(time_zone: "International Date Line West")
      code(utc(2026, 11, 11, 20), utc(2026, 11, 11, 21))
      sync_at utc(2026, 11, 11, 23)
      code(utc(2026, 11, 12, 20), utc(2026, 11, 12, 21))
      sync_at utc(2026, 11, 13, 13)

      assert_equal 14_400, ledger
    end

    test "with no zone change every date keeps asking for the same local midnight window" do
      @user.update!(time_zone: "Tokyo")
      connect_hackatime(@user)
      code(utc(2026, 11, 10, 1), utc(2026, 11, 10, 2))

      sync_at utc(2026, 11, 11, 3)
      first = @fake.requests_for("GET", PROJECTS).map { |r| [ r.query["start_date"], r.query["end_date"] ] }
      sync_at utc(2026, 11, 11, 4)
      second = @fake.requests_for("GET", PROJECTS).map { |r| [ r.query["start_date"], r.query["end_date"] ] }.drop(first.size)

      assert_equal first, second
      assert_includes first, [ "2026-11-11T00:00:00.000+09:00", "2026-11-11T23:59:59.999+09:00" ]
      assert_equal 3_600, ledger
    end

    test "manual credits and adjustments are untouched by a zone change" do
      @user.update!(time_zone: "International Date Line West")
      connect_hackatime(@user)
      code(utc(2026, 11, 11, 2), utc(2026, 11, 11, 4))
      travel_to utc(2026, 11, 11, 6) do
        Hours::Credit.call(user: @user, seconds: 900, source: "manual", idempotency_key: "manual:1", local_date: Date.new(2026, 11, 10), note: "Workshop")
        Hours::Credit.call(user: @user, seconds: -300, source: "adjustment", idempotency_key: "adj:1", local_date: Date.new(2026, 11, 10), note: "Fix")
      end
      sync_at utc(2026, 11, 11, 6)

      @user.update!(time_zone: "Nuku'alofa")
      travel_to utc(2026, 11, 11, 7) do
        result = Hours::Credit.call(user: @user.reload, seconds: 600, source: "manual", idempotency_key: "manual:2", local_date: Date.new(2026, 11, 11), note: "Workshop")
        assert result.created?
      end
      sync_at utc(2026, 11, 11, 8)

      assert_equal 7_200 + 900 - 300 + 600, ledger
      assert_equal [ 900, 600 ], HourEntry.where(user_id: @user.id, source: "manual").order(:id).pluck(:seconds)
    end

    test "a Hackatime account moved to a second Battletown account does not bring the first one's hours again" do
      first = @user
      first.update!(time_zone: "UTC")
      connect_hackatime(first, uid: "777")
      code(utc(2026, 11, 10, 9), utc(2026, 11, 10, 11))
      sync_at utc(2026, 11, 10, 12), first
      assert_equal 7_200, ledger(first)
      first.hackatime_connection.destroy!

      second = users(:new_user)
      second.update!(time_zone: "UTC")
      connect_hackatime(second, uid: "777")
      code(utc(2026, 11, 11, 9), utc(2026, 11, 11, 10))
      sync_at utc(2026, 11, 11, 12), second

      assert_equal 7_200, ledger(first)
      assert_equal 3_600, ledger(second)
    end
  end
end
