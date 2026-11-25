require "test_helper"
require_relative "../../support/ships_test_support"

# A project's coded time for the staff views: counted dates only, and nothing before the project time cutoff.
class Projects::CodedTimeTest < ActiveSupport::TestCase
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }

  setup do
    @user = users(:onboarded)
    @project = make_project(@user)
    code(@user, D[19], 3 * HOUR)
    code(@user, D[23], HOUR)
    code(@user, D[24], 1800)
    @cutoff = Ships::Config.current.with(project_time_from: D[23])
  end

  def queue_total(ships_config)
    sql = Projects::CodedTime.totals_sql(ships_config: ships_config)
    ActiveRecord::Base.connection.select_value("SELECT coded_seconds FROM (#{sql}) totals WHERE project_id = #{@project.id}").to_i
  end

  test "the per-date totals leave out time before the cutoff" do
    assert_equal({ D[23] => HOUR, D[24] => 1800 }, Projects::CodedTime.seconds_by_date(@project, ships_config: @cutoff))
    assert_equal 3, Projects::CodedTime.seconds_by_date(@project).size, "no cutoff in the test environment"
  end

  test "the staff queue's SQL totals agree with the per-date totals, with and without the cutoff" do
    assert_equal HOUR + 1800, queue_total(@cutoff)
    assert_equal 4 * HOUR + 1800, queue_total(@cutoff.with(project_time_from: nil))
  end
end
