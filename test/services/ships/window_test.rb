require "test_helper"
require_relative "../../support/ships_test_support"

class Ships::WindowTest < ActiveSupport::TestCase
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }

  setup do
    @user = users(:onboarded)
    @project = make_project(@user)
  end

  def window = Ships::Window.call(@project)

  test "counts only time on Hackatime projects linked to this project" do
    code(@user, D[9], 2 * HOUR)
    code(@user, D[10], HOUR, hackatime: "other-thing")
    HourEntry.create!(user: @user, local_date: D[10], seconds: HOUR, source: "manual", note: "no project", idempotency_key: "np")
    other = make_project(@user, name: "Other", hackatime: "other-thing")
    code(users(:new_user), D[9], 5 * HOUR) # someone else's entries with the same name never count

    assert_equal 2 * HOUR, window.seconds
    assert_equal [ D[9], D[9] ], [ window.start_date, window.end_date ]
    assert_equal HOUR, Ships::Window.call(other).seconds
  end

  test "several linked Hackatime projects add up, with the first and last dates" do
    @project.hackatime_links.create!(user_id: @user.id, hackatime_project: "space-farm-assets", link_method: "manual")
    code(@user, D[8], HOUR)
    code(@user, D[10], 30 * 60, hackatime: "space-farm-assets")
    result = window
    assert_equal HOUR + 1800, result.seconds
    assert_equal [ D[8], D[10] ], [ result.start_date, result.end_date ]
    assert_equal({ D[8] => HOUR, D[10] => 1800 }, result.seconds_by_date)
    assert_equal 0, result.hours_since_previous_ship_before_window
  end

  test "a project with no linked Hackatime project or no hours has an empty window" do
    unlinked = make_project(@user, name: "Loose", hackatime: nil)
    assert Ships::Window.call(unlinked).empty?
    assert_nil Ships::Window.call(unlinked).start_date
    assert window.empty?
  end

  test "negative adjustments net out and a day that nets to zero is left out" do
    code(@user, D[9], HOUR)
    HourEntry.create!(user: @user, local_date: D[9], seconds: -HOUR, source: "adjustment", note: "fix", hackatime_project: "space-farm", idempotency_key: "adj")
    code(@user, D[10], 600)
    assert_equal({ D[10] => 600 }, window.seconds_by_date)
  end

  test "starts on the local date after the previous submitted or approved ship" do
    code(@user, D[8], HOUR)
    code(@user, D[9], HOUR)
    first = submit_ship(@project)
    assert_equal D[9], first.window_end_date
    code(@user, D[9], 600) # same day, after submitting: belongs to no ship (whole dates are the unit)
    code(@user, D[10], 2 * HOUR)
    assert_equal({ D[10] => 2 * HOUR }, window.seconds_by_date)
    first.update_columns(status: "approved", approved_seconds: HOUR, reviewed_at: Time.current)
    assert_equal({ D[10] => 2 * HOUR }, window.seconds_by_date)
  end

  test "a rejected or withdrawn ship gives its window back" do
    code(@user, D[9], HOUR)
    ship = submit_ship(@project)
    assert window.empty?
    ship.update_columns(status: "withdrawn")
    assert_equal HOUR, window.seconds
    ship.update_columns(status: "rejected", rejection_reason: "no", reviewed_at: Time.current)
    assert_equal HOUR, window.seconds
  end

  test "a draft does not take the window" do
    code(@user, D[9], HOUR)
    submit_ship(@project, submit: false)
    assert_equal HOUR, window.seconds
  end

  test "dates are the frozen local dates, so time zones and daylight saving are already settled in the ledger" do
    # 2026-11-01 is the day US clocks fall back: 25 local hours. Entries credited with an instant keep the user's local date.
    @user.update_columns(time_zone: "America/New_York")
    travel_to(Time.utc(2026, 11, 3, 12)) do
      Hours::Credit.call(user: @user, seconds: HOUR, source: "manual", at: Time.utc(2026, 11, 2, 3, 30), hackatime_project: "space-farm", note: "t", idempotency_key: "dst-1") # Nov 1, 22:30 local
      Hours::Credit.call(user: @user, seconds: HOUR, source: "manual", at: Time.utc(2026, 11, 2, 6, 30), hackatime_project: "space-farm", note: "t", idempotency_key: "dst-2") # Nov 2, 01:30 local
    end
    assert_equal({ D[1] => HOUR, D[2] => HOUR }, window.seconds_by_date)
  end
end
