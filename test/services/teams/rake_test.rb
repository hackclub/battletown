require "test_helper"
require "rake"

# bin/rails team:pay_pending: reports the scan, and does nothing while the flag is off.
class Teams::RakeTest < ActiveSupport::TestCase
  setup { Rails.application.load_tasks unless Rake::Task.task_defined?("team:pay_pending") }

  def run_task
    task = Rake::Task["team:pay_pending"]
    task.reenable
    original = $stdout
    $stdout = StringIO.new
    task.invoke
    $stdout.string
  ensure
    $stdout = original
  end

  test "it prints the scan counts when the flag is on" do
    with_feature(:team) { assert_equal "team:pay_pending enabled=true scanned=0 paid=0\n", run_task }
  end

  test "it reports the flag off and scans nothing" do
    without_feature(:team) { assert_equal "team:pay_pending enabled=false scanned=0 paid=0\n", run_task }
  end
end
