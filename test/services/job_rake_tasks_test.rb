require "test_helper"
require "rake"

# The scheduled rake tasks write a job_runs row and keep printing and exiting exactly as before.
class JobRakeTasksTest < ActiveSupport::TestCase
  setup { Rails.application.load_tasks unless Rake::Task.task_defined?("game:settle") }

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    exited = nil
    out, = capture_io do
      task.invoke
    rescue SystemExit => error
      exited = error
    end
    [ out, exited ]
  end

  test "a task that finishes leaves an ok run with its counts, and prints what it printed before" do
    out, exited = run_task("privacy:purge_tokens")

    assert_nil exited
    assert_equal "privacy:purge_tokens deleted=0\n", out
    run = JobRun.find_by!(name: "privacy:purge_tokens")
    assert_equal [ "ok", { "deleted" => 0 } ], [ run.status, run.counts ]
  end

  test "game:settle that fails a user still exits 1, and the run is failed" do
    stub_method(Game::Settle, :all, -> { { users: 2, days: 3, errors: 1 } }) do
      out, exited = run_task("game:settle")

      assert_equal 1, exited.status
      assert_equal "game:settle users=2 days_written=3 errors=1\n", out
    end
    run = JobRun.find_by!(name: "game:settle")
    assert_equal [ "failed", "SystemExit", { "users" => 2, "days" => 3, "errors" => 1 } ], [ run.status, run.error_class, run.counts ]
  end

  test "game:settle with no failures exits normally and the run is ok" do
    stub_method(Game::Settle, :all, -> { { users: 2, days: 3, errors: 0 } }) do
      _out, exited = run_task("game:settle")
      assert_nil exited
    end
    assert_equal "ok", JobRun.find_by!(name: "game:settle").status
  end

  test "a task behind a flag that is off records that it skipped" do
    out, = run_task("quests:evaluate")

    assert_equal "quests:evaluate skipped (the quests flag is off)\n", out
    assert_equal({ "skipped" => 1 }, JobRun.find_by!(name: "quests:evaluate").counts)
  end

  test "notifications:dispatch records the numbers of both channels" do
    run_task("notifications:dispatch")

    counts = JobRun.find_by!(name: "notifications:dispatch").counts
    assert_equal %w[email_cancelled email_deferred email_enabled email_failed email_halted email_retried email_sent email_skipped
                    slack_cancelled slack_deferred slack_enabled slack_failed slack_halted slack_retried slack_sent slack_skipped], counts.keys.sort
  end

  test "a task that raises leaves a failed run with the class name and raises as before" do
    stub_method(PrivacyRequestToken, :purge_expired, -> { raise IOError, "disk detail with private text" }) do
      assert_raises(IOError) { run_task("privacy:purge_tokens") }
    end
    run = JobRun.find_by!(name: "privacy:purge_tokens")
    assert_equal [ "failed", "IOError" ], [ run.status, run.error_class ]
    assert_not_includes run.attributes.values.join, "private text"
  end
end
