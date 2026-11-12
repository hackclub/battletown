require "test_helper"
require_relative "../../support/ships_test_support"

class AdminUsers::HoursAdjustmentTest < ActiveSupport::TestCase
  include ShipsTestSupport

  setup do
    travel_to Time.utc(2026, 11, 12, 15)
    @staff = users(:onboarded)
    @user = users(:new_user)
    @user.update_columns(time_zone: "UTC")
    @token = AdminUsers::Adjustment.new_token
  end

  def adjustment(**overrides)
    AdminUsers::HoursAdjustment.new(**{ staff: @staff, user: @user, direction: "add", date: "2026-11-10", minutes: "30",
                                        reason: "Hackatime missed a session", token: @token }.merge(overrides))
  end

  test "adding time writes one adjustment entry and one audit event, in the ledger's own terms" do
    outcome = adjustment.apply!
    assert_not outcome.duplicate?
    entry = outcome.record
    assert_equal [ "adjustment", 1800, Date.new(2026, 11, 10), "Hackatime missed a session", "admin:#{@staff.id}", "admin_adjust:#{@token}" ],
                 [ entry.source, entry.seconds, entry.local_date, entry.note, entry.created_by, entry.idempotency_key ]
    event = AdminAuditEvent.sole
    assert_equal [ @staff.id, "hours_adjusted", "User", @user.id ], [ event.actor_id, event.action, event.subject_type, event.subject_id ]
    assert_equal({ "local_date" => "2026-11-10", "seconds" => 1800, "reason" => "Hackatime missed a session", "entry_id" => entry.id }, event.metadata)
    assert_equal 1800, Hours::Totals.seconds_for_date(@user, Date.new(2026, 11, 10))
  end

  test "taking time off writes a negative entry and never edits the earlier rows" do
    original = code(@user, Date.new(2026, 11, 10), 3600)
    outcome = adjustment(direction: "subtract", minutes: "20").apply!
    assert_equal(-1200, outcome.record.seconds)
    assert_equal 3600, original.reload.seconds
    assert_equal 2400, Hours::Totals.seconds_for_date(@user, Date.new(2026, 11, 10))
    assert_equal(-1200, AdminAuditEvent.sole.metadata["seconds"])
  end

  test "the same token twice changes the ledger once and records one audit event" do
    first = adjustment.apply!
    second = adjustment.apply!
    assert second.duplicate?
    assert_equal first.record.id, second.record.id
    assert_equal 1, HourEntry.where(user_id: @user.id, source: "adjustment").count
    assert_equal 1, AdminAuditEvent.count
    # Even a changed amount under the same token changes nothing.
    assert adjustment(minutes: "99").apply!.duplicate?
    assert_equal 1800, HourEntry.where(user_id: @user.id, source: "adjustment").sum(:seconds)
  end

  test "a different token is a different adjustment" do
    adjustment.apply!
    adjustment(token: AdminUsers::Adjustment.new_token).apply!
    assert_equal 3600, HourEntry.where(user_id: @user.id, source: "adjustment").sum(:seconds)
    assert_equal 2, AdminAuditEvent.count
  end

  test "bounds on the amount: zero, negative text, the maximum and one over" do
    [ "0", "-5", "abc", "", "1.5", "1441", "999999", " 5" ].each do |minutes|
      form = adjustment(minutes: minutes)
      assert_not form.valid?, "#{minutes.inspect} must be refused"
      assert_includes form.errors.attribute_names, :minutes
    end
    assert adjustment(minutes: "1").valid?
    assert adjustment(minutes: "1440").valid?
    assert_equal 86_400, adjustment(minutes: "1440").seconds
    code(@user, Date.new(2026, 11, 10), 43_200)
    code(@user, Date.new(2026, 11, 10), 43_200)
    assert_equal(-86_400, adjustment(minutes: "1440", direction: "subtract").seconds)
    assert adjustment(minutes: "1440", direction: "subtract").valid?, "a whole day's worth can come off a day that has it"
  end

  test "a day cannot be taken below zero or pushed past 24 hours" do
    code(@user, Date.new(2026, 11, 10), 600)
    over = adjustment(direction: "subtract", minutes: "11")
    assert_not over.valid?
    assert_match(/more than the 10 minutes recorded/, over.errors.full_messages.to_sentence)
    assert adjustment(direction: "subtract", minutes: "10").valid?, "exactly the recorded time may be taken off"
    assert_raises(AdminUsers::Adjustment::Invalid) { over.apply! }
    assert_equal 0, HourEntry.where(user_id: @user.id, source: "adjustment").count

    code(@user, Date.new(2026, 11, 9), 43_200)
    code(@user, Date.new(2026, 11, 9), 43_200)
    full = adjustment(date: "2026-11-09", minutes: "1")
    assert_not full.valid?
    assert_match(/more than 24 hours/, full.errors.full_messages.to_sentence)
  end

  test "adjustments are not clamped by the daily cap, but the confirm step can tell" do
    code(@user, Date.new(2026, 11, 10), 43_200)
    form = adjustment(minutes: "60")
    assert form.valid?
    assert form.past_daily_cap?
    assert_equal 3600, form.apply!.record.seconds, "not clamped to the cap"
    assert_equal 46_800, HourEntry.where(user_id: @user.id, local_date: Date.new(2026, 11, 10)).sum(:seconds)
    assert_not adjustment(date: "2026-11-09", minutes: "60").past_daily_cap?
  end

  test "dates: nonsense, before the first counted day, and later than their tomorrow" do
    [ "", "yesterday", "2026-13-40", "2026-11-1", "10/11/2026", "2026-11-10; DROP TABLE users" ].each do |date|
      form = adjustment(date: date)
      assert_not form.valid?, date.inspect
      assert_includes form.errors.attribute_names, :date
    end
    assert_not adjustment(date: "2025-12-31").valid?, "before sign-up (2026-01-01) it would change nothing"
    assert adjustment(date: "2026-01-01").valid?
    assert adjustment(date: "2026-11-13").valid?, "their tomorrow is allowed"
    assert_not adjustment(date: "2026-11-14").valid?
    assert adjustment(date: "2026-02-02").valid?, "adjustments are not limited by the backfill window"
  end

  test "the user's own time zone decides today and tomorrow" do
    # 2026-11-12 15:00 UTC is already 2026-11-13 in Auckland (UTC+13) and still 2026-11-12 in Los Angeles.
    @user.update_columns(time_zone: "Auckland")
    assert adjustment(date: "2026-11-14").valid?
    assert_not adjustment(date: "2026-11-15").valid?
    @user.update_columns(time_zone: "Pacific Time (US & Canada)")
    assert adjustment(date: "2026-11-13").valid?
    assert_not adjustment(date: "2026-11-14").valid?
  end

  test "the date is stored as the local date given, also across a daylight saving change" do
    @user.update_columns(time_zone: "Eastern Time (US & Canada)")
    travel_to Time.utc(2026, 11, 2, 12) # the clocks went back on 2026-11-01: a 25-hour local day
    form = adjustment(date: "2026-11-01", minutes: "45")
    assert_equal 45 * 60, form.apply!.record.seconds
    assert_equal Date.new(2026, 11, 1), HourEntry.find_by!(user_id: @user.id, source: "adjustment").local_date
    assert_equal 2700, Hours::Totals.seconds_for_date(@user, Date.new(2026, 11, 1))
    assert_equal 0, Hours::Totals.seconds_for_date(@user, Date.new(2026, 11, 2))
  end

  test "reason: required, 5 to 200 characters, tidied, and no contact details" do
    [ "", "   ", "four", "x" * 201 ].each do |reason|
      form = adjustment(reason: reason)
      assert_not form.valid?, reason.inspect
      assert_includes form.errors.attribute_names, :reason
    end
    assert adjustment(reason: "fives").valid?
    assert adjustment(reason: "x" * 200).valid?
    assert_equal "a b c d e", adjustment(reason: "  a\n b\t c   d \u0000e ").reason
    assert_not adjustment(reason: "mail kid@example.test about it").valid?
    assert_not adjustment(reason: "call 555 123 4567 now").valid?
    assert adjustment(reason: "Fixed 2026-11-10 session").valid?
  end

  test "a missing or malformed token is refused" do
    [ nil, "", "short", "g" * 32, "A" * 32, "a" * 33 ].each do |token|
      assert_not adjustment(token: token).valid?, token.inspect
    end
    assert_raises(AdminUsers::Adjustment::Invalid) { adjustment(token: nil).apply! }
    assert_equal 0, HourEntry.where(source: "adjustment").count
  end

  test "direction must be add or subtract" do
    [ nil, "", "remove", "ADD", "add; x" ].each { |direction| assert_not adjustment(direction: direction).valid?, direction.inspect }
  end

  test "staff cannot adjust their own hours" do
    own = AdminUsers::HoursAdjustment.new(staff: @staff, user: @staff, direction: "add", date: "2026-11-10", minutes: "30", reason: "Fixing mine", token: @token)
    assert_not own.valid?
    assert_includes own.errors.full_messages.to_sentence, AdminUsers::Adjustment::OWN_ACCOUNT_MESSAGE
    assert_raises(AdminUsers::Adjustment::Invalid) { own.apply! }
    assert_equal 0, HourEntry.where(user_id: @staff.id, source: "adjustment").count
    assert_equal 0, AdminAuditEvent.count
  end

  test "a refused adjustment writes neither an entry nor an audit event" do
    assert_raises(AdminUsers::Adjustment::Invalid) { adjustment(minutes: "0").apply! }
    assert_equal 0, HourEntry.where(source: "adjustment").count
    assert_equal 0, AdminAuditEvent.count
  end

  test "if the audit row cannot be written the ledger entry is rolled back" do
    original = AdminAudit.method(:record!)
    AdminAudit.define_singleton_method(:record!) { |**| raise ActiveRecord::StatementInvalid, "boom" }
    begin
      assert_raises(ActiveRecord::StatementInvalid) { adjustment.apply! }
    ensure
      AdminAudit.define_singleton_method(:record!, original)
    end
    assert_equal 0, HourEntry.where(source: "adjustment").count
  end

  test "a settled day is flagged on the confirm step and its streak result stays as it was" do
    result = DailyResult.create!(user: @user, local_date: Date.new(2026, 11, 10), raw_seconds: 0, quick_met: false, goal_met: false, streak_15: 0, goal_streak: 0, freeze_available: true)
    form = adjustment
    assert form.settled_day?
    form.apply!
    assert_equal [ 0, 0 ], result.reload.then { |row| [ row.raw_seconds, row.streak_15 ] }
    assert_not adjustment(date: "2026-11-09").settled_day?
  end
end
