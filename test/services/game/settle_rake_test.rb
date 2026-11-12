require "test_helper"
require "rake"
require_relative "../../support/coins_helper"

# bin/rails game:settle: settles everyone, prints counts, and fails the run (after trying everyone) when a user fails,
# so a scheduled job shows the failure instead of hiding it in its output line.
class Game::SettleRakeTest < ActiveSupport::TestCase
  include CoinsHelper

  # Raises for one user and reports nothing for everyone else.
  class FailingFor
    def initialize(user_id) = @user_id = user_id

    def seconds_by_date(user, _range)
      raise "boom" if user.id == @user_id

      {}
    end
  end

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("game:settle")
    @user = build_user(created_on: Date.new(2026, 11, 1))
    @other = build_user(created_on: Date.new(2026, 11, 1))
  end

  teardown { Game::HoursSource.reset! }

  # [stdout, the SystemExit raised or nil]; stdout is kept even when the task exits.
  def run_task
    task = Rake::Task["game:settle"]
    task.reenable
    original = $stdout
    $stdout = StringIO.new
    exited = nil
    begin
      task.invoke
    rescue SystemExit => error
      exited = error
    end
    [ $stdout.string, exited ]
  ensure
    $stdout = original
  end

  test "exits normally and prints the counts when every user settles" do
    Game::HoursSource.current = StubHoursSource.new
    travel_to(Time.utc(2026, 11, 3, 12)) do
      out, exited = run_task
      assert_nil exited
      assert_match(/\Agame:settle users=\d+ days_written=\d+ errors=0\n\z/, out)
    end
  end

  test "settles everyone it can, prints the counts, then exits non-zero when some users failed" do
    Game::HoursSource.current = FailingFor.new(@user.id)
    travel_to(Time.utc(2026, 11, 3, 12)) do
      out, exited = run_task
      assert_match(/\Agame:settle users=\d+ days_written=\d+ errors=1\n\z/, out)
      assert_not_nil exited, "a run with errors must not exit 0"
      assert_equal 1, exited.status
    end
    assert DailyResult.where(user_id: @other.id).exists?, "the users after or before the failing one are still settled"
    assert_not DailyResult.where(user_id: @user.id).exists?
  end
end
