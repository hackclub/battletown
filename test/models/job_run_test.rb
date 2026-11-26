require "test_helper"

# JobRun.record: the wrapper every scheduled rake task runs inside. It writes counts and a class name, never text from an exception, and it
# never changes how the task ends.
class JobRunTest < ActiveSupport::TestCase
  test "a task that finishes is recorded as ok with its counts and how long it took" do
    result = JobRun.record("game:settle") do |counts|
      counts.merge!(users: 3, days: 7, errors: 0)
      :done
    end

    assert_equal :done, result
    run = JobRun.find_by!(name: "game:settle")
    assert_equal "ok", run.status
    assert_equal({ "users" => 3, "days" => 7, "errors" => 0 }, run.counts)
    assert run.finished_at
    assert_operator run.duration_seconds, :>=, 0
    assert_nil run.error_class
  end

  test "a run that raises is recorded as failed with the class name only, and the exception goes on" do
    error = assert_raises(ArgumentError) do
      JobRun.record("hackatime:sync") { |counts| counts[:users] = 1 and raise ArgumentError, "secret detail: token=abc123 for someone@example.com" }
    end

    assert_match(/secret detail/, error.message)
    run = JobRun.find_by!(name: "hackatime:sync")
    assert_equal "failed", run.status
    assert_equal "ArgumentError", run.error_class
    assert_equal({ "users" => 1 }, run.counts)
    assert_not_includes JobRun.pluck(:error_class, :counts).flatten.join, "abc123"
    assert_not_includes JobRun.pluck(:error_class, :counts).flatten.join, "example.com"
  end

  test "exit 1 and abort are recorded as failed and still exit, exit 0 is ok" do
    exited = assert_raises(SystemExit) { JobRun.record("game:settle") { exit 1 } }
    assert_equal 1, exited.status
    aborted = nil
    capture_io { aborted = assert_raises(SystemExit) { JobRun.record("quests:evaluate") { abort "boom: private text" } } }
    assert_equal 1, aborted.status
    assert_raises(SystemExit) { JobRun.record("team:pay_pending") { exit 0 } }

    assert_equal [ "failed", "SystemExit" ], JobRun.find_by!(name: "game:settle").then { |run| [ run.status, run.error_class ] }
    assert_equal "failed", JobRun.find_by!(name: "quests:evaluate").status
    assert_equal "ok", JobRun.find_by!(name: "team:pay_pending").status
    assert_not_includes JobRun.pluck(:error_class).join, "private"
  end

  test "next out of the block is a normal finish" do
    JobRun.record("returning:evaluate") { |counts| counts[:skipped] = 1 and next }

    assert_equal "ok", JobRun.find_by!(name: "returning:evaluate").status
  end

  test "only whole numbers under a plain lowercase key are kept as counts" do
    JobRun.record("notifications:dispatch") do |counts|
      counts.merge!(sent: 4, "failed" => 0, enabled: true, halted: false, ratio: 0.5, note: "text", "Bad Key" => 1, nested: { a: 1 }, nothing: nil)
    end

    assert_equal({ "sent" => 4, "failed" => 0, "enabled" => 1, "halted" => 0 }, JobRun.find_by!(name: "notifications:dispatch").counts)
  end

  test "a counts hash with a default value (Hash.new(0)) is kept as it is" do
    JobRun.record("hackatime:sync") { |run| run.merge!(Hash.new(0).tap { |counts| counts[:synced] += 2 }) }

    assert_equal({ "synced" => 2 }, JobRun.find_by!(name: "hackatime:sync").counts)
  end

  test "the task still runs when the run cannot be written, and nothing is raised for the recording" do
    ran = false
    stub_method(JobRun, :create!, ->(*, **) { raise ActiveRecord::StatementInvalid, "relation job_runs does not exist" }) do
      JobRun.record("game:settle") { ran = true }
    end

    assert ran
    assert_equal 0, JobRun.count
  end

  test "a name that is not a task name is refused before anything runs" do
    ran = false
    [ "settle", "Game:Settle", "game:settle; DROP", "game:#{'a' * 60}", nil ].each do |name|
      assert_raises(ArgumentError) { JobRun.record(name) { ran = true } }
    end
    assert_not ran
  end

  test "a run that is still going has no end and no duration" do
    run = JobRun.create!(name: "game:settle", started_at: Time.current)

    assert_equal "running", run.status
    assert_nil run.duration_seconds
    assert_not run.ok?
  end

  test "the database refuses an unknown status and counts that are not an object" do
    assert_raises(ActiveRecord::StatementInvalid) { JobRun.insert_all!([ { name: "game:settle", started_at: Time.current, status: "weird" } ]) }
    assert_raises(ActiveRecord::StatementInvalid) { JobRun.insert_all!([ { name: "game:settle", started_at: Time.current, counts: [ 1 ] } ]) }
  end
end
