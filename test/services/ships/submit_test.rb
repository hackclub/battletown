require "test_helper"
require_relative "../../support/ships_test_support"

class Ships::SubmitTest < ActiveSupport::TestCase
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }

  setup do
    @user = users(:onboarded)
    @project = make_project(@user)
  end

  def events(name)
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |*args| captured << args.last }
    yield
    captured
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "submitting snapshots the window and emits the event with the ship id only" do
    code(@user, D[8], 2 * HOUR)
    code(@user, D[9], HOUR)
    ship = nil
    payloads = events("ship_submitted.battletown") { ship = submit_ship(@project) }

    assert ship.persisted?
    assert_equal "submitted", ship.status
    assert_equal 3 * HOUR, ship.coded_seconds
    assert_equal [ D[8], D[9] ], [ ship.window_start_date, ship.window_end_date ]
    assert_equal({ "2026-11-08" => 2 * HOUR, "2026-11-09" => HOUR }, ship.daily_seconds)
    assert_not_nil ship.submitted_at
    assert_equal [ { ship_id: ship.id } ], payloads
  end

  test "hours coded after submitting belong to the next ship" do
    code(@user, D[8], HOUR)
    first = submit_ship(@project)
    code(@user, D[9], 2 * HOUR)
    first.update_columns(status: "approved", approved_seconds: HOUR, reviewed_at: Time.current)

    second = submit_ship(@project)
    assert_equal 2 * HOUR, second.coded_seconds
    assert_equal D[9], second.window_start_date
    assert_equal HOUR, first.reload.coded_seconds, "the first snapshot never moves"
  end

  test "a project with no linked Hackatime project cannot be shipped" do
    loose = make_project(@user, name: "Loose", hackatime: nil)
    assert_raises(Ships::Submit::NoHackatimeLink) { submit_ship(loose) }
    assert_equal 0, Ship.count
  end

  test "a linked project with no hours cannot be shipped" do
    assert_raises(Ships::Submit::NoHours) { submit_ship(@project) }
  end

  test "under the minimum hours cannot be submitted but can be saved as a draft" do
    code(@user, D[9], 3000)
    assert_raises(Ships::Submit::TooFewHours) { submit_ship(@project) }
    draft = submit_ship(@project, submit: false)
    assert draft.persisted?
    assert_equal "draft", draft.status
    assert_nil draft.submitted_at
  end

  test "exactly the minimum is enough" do
    code(@user, D[9], Ships::Config.current.min_seconds)
    assert submit_ship(@project).persisted?
  end

  test "the form must be valid: a missing description or repo saves nothing" do
    code(@user, D[9], HOUR)
    ship = Ships::Submit.call(project: @project, attributes: { description: "", repo_url: "" }, submit: true)
    assert_not ship.persisted?
    assert ship.errors[:description].any?
    assert ship.errors[:repo_url].any?
    assert_equal 0, Ship.count
  end

  test "only one open ship per project" do
    code(@user, D[9], HOUR)
    first = submit_ship(@project)
    error = assert_raises(Ships::Submit::AlreadyOpen) { submit_ship(@project) }
    assert_equal first, error.ship
    assert_equal 1, Ship.count
  end

  test "withdrawing reopens the window" do
    code(@user, D[9], HOUR)
    ship = submit_ship(@project)
    assert Ships::Window.call(@project).empty?
    assert Ships::Withdraw.call(ship: ship)
    assert_equal "withdrawn", ship.reload.status
    assert_equal HOUR, Ships::Window.call(@project).seconds
    assert_equal HOUR, submit_ship(@project).coded_seconds
  end

  test "withdrawing a decided ship does nothing" do
    code(@user, D[9], HOUR)
    ship = submit_ship(@project)
    ship.update_columns(status: "approved", approved_seconds: HOUR, reviewed_at: Time.current)
    assert_not Ships::Withdraw.call(ship: ship)
    assert_equal "approved", ship.reload.status
  end

  test "a rejected ship can be fixed and resubmitted as a new ship for the same window" do
    code(@user, D[9], HOUR)
    first = submit_ship(@project)
    Ships::Reject.call(ship: first, reviewer: users(:new_user), reason: "The demo link does not open")
    assert_equal "rejected", first.reload.status

    second = submit_ship(@project, description: "Fixed the demo")
    assert second.persisted?
    assert_not_equal first.id, second.id
    assert_equal first.coded_seconds, second.coded_seconds
    assert_equal [ first.window_start_date, first.window_end_date ], [ second.window_start_date, second.window_end_date ]
  end

  test "a draft is re-snapshotted when it is submitted" do
    code(@user, D[9], HOUR)
    draft = submit_ship(@project, submit: false)
    code(@user, D[10], HOUR)
    submitted = Ships::Submit.call(project: @project, ship: draft, attributes: ship_attrs, submit: true)
    assert_equal draft.id, submitted.id
    assert_equal 2 * HOUR, submitted.coded_seconds
    assert_equal "submitted", submitted.status
  end

  test "only a draft can be changed" do
    code(@user, D[9], HOUR)
    ship = submit_ship(@project)
    assert_raises(Ships::Submit::NotEditable) { Ships::Submit.call(project: @project, ship: ship, attributes: ship_attrs, submit: true) }
  end

  test "linked time is read at submission, so unlinking afterwards does not change the snapshot" do
    code(@user, D[9], HOUR)
    ship = submit_ship(@project)
    @project.hackatime_links.destroy_all
    assert_equal HOUR, ship.reload.coded_seconds
  end
end
