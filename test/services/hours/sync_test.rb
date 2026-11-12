require "test_helper"

class Hours::SyncTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 11, 11, 12, 0, 0)
  DAY = Date.new(2026, 11, 11)

  setup do
    @user = users(:onboarded)
    travel_to NOW
  end

  teardown { travel_back }

  def row(seconds, project: nil, date: DAY) = Hackatime::DaySeconds.new(date: date, seconds: seconds, project: project)

  def sync(*rows, **options) = Hours::Sync.call(rows, user: @user, **options)

  def ledger(project: nil) = HourEntry.where(user: @user, hackatime_project: project).order(:id).pluck(:seconds)

  # Captures what the app logs while the block runs.
  def logged
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  test "credits a reported day total for a project" do
    summary = sync(row(3_600, project: "my-game"))

    assert_equal [ 3_600 ], ledger(project: "my-game")
    entry = HourEntry.last
    assert_equal [ "hackatime", "hackatime:2026-11-11:my-game:3600", "hackatime:sync", DAY ], [ entry.source, entry.idempotency_key, entry.created_by, entry.local_date ]
    assert_equal 3_600, summary.credited_seconds
    assert_equal 1, summary.credited_days
  end

  test "running the same report again changes nothing" do
    sync(row(3_600, project: "g"))
    summary = sync(row(3_600, project: "g"))

    assert_equal [ 3_600 ], ledger(project: "g")
    assert_equal 0, summary.credited_seconds
    assert_equal 1, summary.unchanged_days
  end

  test "a larger total credits only the difference, under a key that names the new total" do
    sync(row(3_600, project: "g"))
    summary = sync(row(5_400, project: "g"))

    assert_equal [ 3_600, 1_800 ], ledger(project: "g")
    assert_equal [ "hackatime:2026-11-11:g:3600", "hackatime:2026-11-11:g:5400" ], HourEntry.order(:id).pluck(:idempotency_key)
    assert_equal 1_800, summary.credited_seconds
  end

  test "a lower total is never clawed back: it is skipped, counted and logged by count only" do
    sync(row(3_600, project: "secret-project-name"))
    summary = nil
    log = logged { summary = sync(row(1_000, project: "secret-project-name")) }

    assert_equal [ 3_600 ], ledger(project: "secret-project-name")
    assert_equal 1, summary.skipped_negative
    assert_includes log, "skipped_negative=1"
    assert_not_includes log, "secret-project-name"
    assert_not_includes log, @user.slack_id.to_s if @user.slack_id.present?
  end

  test "projects and dates are tracked separately" do
    sync(row(600, project: "a"), row(900, project: "b"), row(1_200), row(300, project: "a", date: DAY - 1))

    assert_equal [ 600 ], ledger(project: "a").first(1)
    assert_equal 4, HourEntry.count
    assert_equal({ DAY => 2_700, DAY - 1 => 300 }, Hours::Totals.seconds_by_date(@user, (DAY - 1)..DAY))
  end

  test "manual credits and adjustments do not count as Hackatime time already credited" do
    Hours::Credit.call(user: @user, seconds: 1_800, source: "manual", note: "Workshop", local_date: DAY, idempotency_key: "w")
    Hours::Credit.call(user: @user, seconds: -600, source: "adjustment", note: "Fix", local_date: DAY, idempotency_key: "f")

    sync(row(3_600))

    assert_equal [ 3_600 ], HourEntry.where(user: @user, source: "hackatime").pluck(:seconds)
    assert_equal 4_800, Hours::Totals.seconds_for_date(@user, DAY)
  end

  test "an adjustment does not stop the same report being treated as already credited" do
    sync(row(3_600, project: "g"))
    Hours::Credit.call(user: @user, seconds: -3_600, source: "adjustment", note: "Idle", local_date: DAY, idempotency_key: "idle")
    sync(row(3_600, project: "g"))

    assert_equal 0, Hours::Totals.seconds_for_date(@user, DAY)
    assert_equal 2, HourEntry.count
  end

  test "the daily cap applies and a capped report is counted" do
    summary = sync(row(86_400, project: "marathon"))

    assert_equal [ 43_200 ], ledger(project: "marathon")
    assert_equal 43_200, summary.credited_seconds

    again = sync(row(86_400, project: "marathon"))
    assert_equal 0, again.credited_seconds
    assert_equal 1, HourEntry.count

    other = sync(row(600, project: "other"))
    assert_equal 1, other.capped
  end

  test "days outside the backfill window are counted as rejected and the rest still sync" do
    summary = sync(row(600, project: "old", date: DAY - 10), row(900, project: "new"))

    assert_equal 1, summary.rejected
    assert_equal 900, summary.credited_seconds
    assert_equal [ 900 ], ledger(project: "new")
  end

  test "a user is synced from a source, by default over the backfill window" do
    source = Class.new do
      include Hackatime::Source

      attr_reader :asked

      def daily_seconds(user:, from:, to:)
        @asked = [ from, to ]
        [ Hackatime::DaySeconds.new(date: Date.new(2026, 11, 10), seconds: 1_500, project: "p") ]
      end
    end.new

    summary = Hours::Sync.call(@user, source: source)

    assert_equal [ Date.new(2026, 11, 8), DAY ], source.asked
    assert_equal 1_500, summary.credited_seconds

    Hours::Sync.call(@user, source: source, from: nil, to: nil)
    assert_equal [ nil, nil ], source.asked
  end

  test "the default source reports nothing" do
    assert_equal 0, Hours::Sync.call(@user).credited_seconds
    assert_equal [], Hackatime::NullSource.new.daily_seconds(user: @user, from: nil, to: nil)
    assert_instance_of Hackatime::NullSource, Hackatime.source
  end

  test "the source duck type must be implemented" do
    assert_raises(NotImplementedError) { Object.new.extend(Hackatime::Source).daily_seconds(user: @user, from: nil, to: nil) }
  end

  test "rows need a user" do
    assert_raises(ArgumentError) { Hours::Sync.call([ row(60) ]) }
  end

  test "keys always fit the column, whatever the project name" do
    long = "p" * 120
    key = Hours::Sync.key_for(date: DAY, project: long, reported: 86_400)
    assert_operator key.length, :<=, 120
    assert_equal key, Hours::Sync.key_for(date: DAY, project: long, reported: 86_400)
    assert_not_equal key, Hours::Sync.key_for(date: DAY, project: "q" * 120, reported: 86_400)
    assert_equal "hackatime:2026-11-11::60", Hours::Sync.key_for(date: DAY, project: nil, reported: 60)

    assert_equal [ 600 ], sync(row(600, project: long)).then { ledger(project: long) }
  end

  test "DaySeconds defaults the project to nil" do
    assert_nil Hackatime::DaySeconds.new(date: DAY, seconds: 5).project
  end
end
