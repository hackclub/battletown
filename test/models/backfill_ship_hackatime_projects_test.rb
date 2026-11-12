require "test_helper"
require_relative "../support/ships_test_support"
require Rails.root.join("db/migrate/20261113035005_add_hackatime_projects_to_ships")

# The data migration that records, on ships saved before names were kept, the Hackatime projects their project links now.
class BackfillShipHackatimeProjectsTest < ActiveSupport::TestCase
  include ShipsTestSupport

  def run_backfill = ActiveRecord::Migration.suppress_messages { AddHackatimeProjectsToShips.new.backfill }

  setup do
    @user = users(:onboarded)
    @project = make_project(@user)
    code(@user, Date.new(2026, 11, 9), HOUR)
    @ship = submit_ship(@project)
    @ship.update_columns(hackatime_projects: [])
  end

  test "fills a legacy ship with its project's current links, and the block then moves with the name" do
    @project.hackatime_links.create!(user_id: @user.id, hackatime_project: "space-farm-assets", link_method: "manual")
    run_backfill
    assert_equal %w[space-farm space-farm-assets], @ship.reload.hackatime_projects

    other = make_project(@user, name: "Space Farm 2", hackatime: nil)
    @project.hackatime_links.find_by!(hackatime_project: "space-farm").destroy!
    other.hackatime_links.create!(user_id: @user.id, hackatime_project: "space-farm", link_method: "manual")
    assert Ships::Window.call(other).empty?
  end

  test "leaves ships that already have names, and ships whose project has no links, alone" do
    unlinked = make_project(@user, name: "Loose", hackatime: nil)
    loose = Ship.new(user: @user, project: unlinked, status: "draft", coded_seconds: HOUR, window_start_date: Date.new(2026, 11, 9),
                     window_end_date: Date.new(2026, 11, 9), daily_seconds: { "2026-11-09" => HOUR })
    loose.save!
    named = make_project(@user, name: "Named", hackatime: "named-thing")
    code(@user, Date.new(2026, 11, 9), HOUR, hackatime: "named-thing")
    kept = submit_ship(named)
    kept.update_columns(hackatime_projects: [ "something-else" ])

    run_backfill
    run_backfill
    assert_equal [], loose.reload.hackatime_projects
    assert_equal [ "something-else" ], kept.reload.hackatime_projects
    assert_equal [ "space-farm" ], @ship.reload.hackatime_projects
  end
end
