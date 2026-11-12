require "test_helper"
require "tempfile"

class Hours::RakeTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 11, 11, 12, 0, 0)

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("hours:import")
    @user = users(:onboarded)
    @user.update_column(:slack_id, "U01ABCDEF")
    travel_to NOW
  end

  teardown { travel_back }

  def run_task(name, *args)
    task = Rake::Task[name]
    task.reenable
    out, err = capture_io { task.invoke(*args) }
    [ out, err ]
  end

  def with_csv(text)
    file = Tempfile.new([ "hours", ".csv" ])
    file.write(text)
    file.flush
    yield file.path
  ensure
    file.close!
  end

  test "hours:import credits the file and prints counts only" do
    csv = <<~CSV
      slack_id,date,seconds,project
      U01ABCDEF,2026-11-11,3600,my-game
      U01ABCDEF,2026-11-10,1800,
      U01ABCDEF,2026-11-01,600,too-old
      U0UNKNOWN,2026-11-11,600,x
      garbage,row
    CSV
    out, = with_csv(csv) { |path| run_task("hours:import", path) }

    assert_equal 5_400, Hours::Totals.seconds_in_range(Date.new(2026, 11, 1)..Date.new(2026, 11, 11))
    assert_includes out, "rows=5 invalid_rows=1 unknown_slack_ids=1 credited_seconds=5400 credited_days=2"
    assert_includes out, "rejected_days=1"
    assert_not_includes out, "U01ABCDEF"
    assert_not_includes out, "my-game"
  end

  test "hours:import is safe to repeat" do
    with_csv("slack_id,date,seconds\nU01ABCDEF,2026-11-11,3600\n") do |path|
      run_task("hours:import", path)
      out, = run_task("hours:import", path)
      assert_includes out, "credited_seconds=0 credited_days=0 unchanged_days=1"
    end
    assert_equal 1, HourEntry.count
  end

  test "hours:import stops with a message on a missing or bad file" do
    err = assert_raises(SystemExit) { run_task("hours:import", "/nonexistent.csv") }
    assert_not err.success?
    with_csv("a,b\n1,2\n") { |path| assert_raises(SystemExit) { run_task("hours:import", path) } }
    assert_raises(SystemExit) { run_task("hours:import") }
  end

  test "hours:credit adds a manual credit" do
    out, = run_task("hours:credit", "U01ABCDEF", "2026-11-11", "1800", "Workshop, part 1")

    assert_includes out, "status=created credited_seconds=1800"
    assert_not_includes out, "U01ABCDEF"
    entry = HourEntry.last
    assert_equal [ "manual", "rake:credit", "Workshop, part 1", 1_800, Date.new(2026, 11, 11) ],
                 [ entry.source, entry.created_by, entry.note, entry.seconds, entry.local_date ]
  end

  test "hours:credit is idempotent for the same date, note and seconds" do
    run_task("hours:credit", "U01ABCDEF", "2026-11-11", "1800", "Workshop")
    out, = run_task("hours:credit", "U01ABCDEF", "2026-11-11", "1800", "Workshop")

    assert_includes out, "status=duplicate credited_seconds=0"
    assert_equal 1, HourEntry.count

    run_task("hours:credit", "U01ABCDEF", "2026-11-11", "600", "Workshop")
    assert_equal 2, HourEntry.count
  end

  test "hours:credit refuses unknown users and bad input" do
    assert_raises(SystemExit) { run_task("hours:credit", "U0NOBODY", "2026-11-11", "60", "x") }
    assert_raises(SystemExit) { run_task("hours:credit", "U01ABCDEF", "nope", "60", "x") }
    assert_raises(SystemExit) { run_task("hours:credit", "U01ABCDEF", "2026-11-11", "lots", "x") }
    assert_raises(SystemExit) { run_task("hours:credit", "U01ABCDEF", "2026-11-11", "60", "") }
    assert_raises(SystemExit) { run_task("hours:credit", "U01ABCDEF", "2026-10-01", "60", "too old") }
    assert_raises(SystemExit) { run_task("hours:credit") }
    assert_equal 0, HourEntry.count
  end
end
