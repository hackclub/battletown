require "test_helper"

# JobSchedule: which scheduled tasks have gone quiet, and that every task in config/job_schedule.yml really records its runs.
class JobScheduleTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 11, 26, 12, 0, 0)

  def ran(name, at:, status: "ok", error_class: nil)
    JobRun.create!(name: name, started_at: at - 5, finished_at: at, status: status, error_class: error_class, counts: {})
  end

  def entry(name) = JobSchedule.status(now: NOW).find { |candidate| candidate.name == name }

  test "a task with a recent success is ok" do
    ran("game:settle", at: NOW - 59.minutes)

    found = entry("game:settle")
    assert_equal :ok, found.state
    assert_equal NOW - 59.minutes, found.last_success_at
    assert_not found.stale?
  end

  test "a task whose last success is older than twice its interval is stale" do
    ran("game:settle", at: NOW - 121.minutes)
    ran("notifications:dispatch", at: NOW - 9.minutes)
    ran("notifications:schedule_all", at: NOW - 49.hours)

    assert_equal :stale, entry("game:settle").state
    assert_equal :ok, entry("notifications:dispatch").state
    assert_includes JobSchedule.stale(now: NOW).map(&:name), "notifications:schedule_all"
    assert_not_includes JobSchedule.stale(now: NOW).map(&:name), "notifications:dispatch"
  end

  test "exactly twice the interval is not yet stale" do
    ran("hackatime:sync", at: NOW - 120.minutes)

    assert_equal :ok, entry("hackatime:sync").state
  end

  test "a failed run does not count as a success, and the last run is still reported" do
    ran("game:settle", at: NOW - 30.minutes)
    ran("game:settle", at: NOW - 5.minutes, status: "failed", error_class: "SystemExit")

    found = entry("game:settle")
    assert_equal :ok, found.state
    assert_equal NOW - 30.minutes, found.last_success_at
    assert_equal "failed", found.last_status
    assert_equal "SystemExit", found.last_error_class
    assert_equal NOW - 5.minutes - 5, found.last_run_at
    assert_equal 5.0, found.last_duration_seconds
  end

  test "a task that never ran is never_run, not stale" do
    found = entry("game:settle")

    assert_equal :never_run, found.state
    assert_nil found.last_run_at
    assert_nil found.last_success_at
    assert_not_includes JobSchedule.stale(now: NOW).map(&:name), "game:settle"
  end

  test "a task behind a flag that is off is off, not never_run or stale, until the flag is on" do
    ran("quests:evaluate", at: NOW - 5.hours)

    assert_equal :off, entry("quests:evaluate").state
    assert_equal :off, entry("team:pay_pending").state
    with_feature(:quests) { assert_equal :stale, entry("quests:evaluate").state }
    with_feature(:team) { assert_equal :never_run, entry("team:pay_pending").state }
  end

  test "it reads two queries however many runs there are" do
    5.times { |index| ran("game:settle", at: NOW - index.minutes) }

    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/flipper/i) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { JobSchedule.status(now: NOW) }
    assert_equal 2, queries.size
  end

  test "every scheduled task is listed, exists as a rake task and records its runs" do
    source = Dir[Rails.root.join("lib/tasks/*.rake")].to_h { |path| [ path, File.read(path) ] }.values.join("\n")
    JobSchedule.jobs.each_key do |name|
      assert_includes source, %(JobRun.record("#{name}")), "#{name} does not wrap its body in JobRun.record"
    end
    assert_equal JobSchedule.jobs.keys.sort, source.scan(/JobRun\.record\("([a-z_]+:[a-z_]+)"\)/).flatten.uniq.sort
  end

  test "intervals are positive whole numbers of minutes and flags are real" do
    JobSchedule.jobs.each do |name, job|
      assert_kind_of Integer, job[:interval_minutes], name
      assert_predicate job[:interval_minutes], :positive?, name
      assert_includes Features::NAMES, job[:flag].to_sym, name if job[:flag]
    end
  end
end
