require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/ships_test_support"

class Bosses::CheckDefeatTest < ActiveSupport::TestCase
  include BossesHelper
  include ShipsTestSupport

  setup do
    @user = users(:onboarded)
    @boss = make_boss(hp_seconds: 3_600)
  end

  # A real submission at a fixed time inside the boss week: coded time on the ledger, then Ships::Submit.
  def submit_real_ship(user, seconds, at: Time.utc(2026, 11, 16, 12), project: nil)
    project ||= make_project(user, name: "Real #{SecureRandom.hex(3)}", hackatime: "real-#{SecureRandom.hex(3)}")
    hackatime = project.hackatime_links.first.hackatime_project
    code(user, at.to_date, seconds, hackatime: hackatime)
    travel_to(at) { Ships::Submit.call(project: project, attributes: ship_attrs, submit: true, now: at) }
  end

  test "one second short is not defeated, exact HP is" do
    ship_damage(@user, 3_599)
    assert_not Bosses::CheckDefeat.call(@boss)
    assert_nil @boss.reload.defeated_at

    ship_damage(@user, 1)
    assert Bosses::CheckDefeat.call(@boss)
    assert @boss.reload.defeated?
  end

  test "the defeat is recorded without reading the picture bytes, and the caller's boss shows it" do
    ship_damage(@user, 4_000)
    reads = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| reads << payload[:sql] if payload[:sql].match?(/SELECT.*"art_content"|SELECT "bosses"\.\*/) }
    assert Bosses::CheckDefeat.call(@boss)
    ActiveSupport::Notifications.unsubscribe(subscriber)
    assert_empty reads
    assert_predicate @boss, :defeated?
    assert_not_predicate @boss, :changed?
  end

  test "call returns true only the first time" do
    ship_damage(@user, 4_000)
    assert Bosses::CheckDefeat.call(@boss)
    first = @boss.reload.defeated_at
    assert_not_nil first
    assert_not Bosses::CheckDefeat.call(@boss)
    assert_equal first, @boss.reload.defeated_at
  end

  test "coding alone never defeats the boss, however much" do
    add_hours(@user, FRIDAY, 20 * HOUR)
    add_hours(users(:new_user), FRIDAY + 1, 20 * HOUR)
    assert_not Bosses::CheckDefeat.call(@boss)
    assert_nil @boss.reload.defeated_at
  end

  test "submitting a ship big enough to cover the health defeats the boss, once" do
    submit_real_ship(@user, 3_600)
    assert @boss.reload.defeated?, "Ships::Submit checks the boss after it commits"
    first = @boss.defeated_at

    other = users(:new_user)
    submit_real_ship(other, 7_200)
    assert_equal first, @boss.reload.defeated_at, "later ships do not move it"
  end

  test "a ship that is too small leaves the boss standing" do
    big = make_boss(starts_on: FRIDAY + 7, hp_seconds: 10 * HOUR)
    submit_real_ship(@user, 2 * HOUR, at: Time.utc(2026, 11, 21, 12))
    assert_equal 2 * HOUR, Bosses::Damage.for(big)
    assert_nil big.reload.defeated_at
  end

  test "a ship submitted outside the boss week does not touch it" do
    ship_damage(@user, 9_999, on: FRIDAY - 1)
    ship_damage(@user, 9_999, on: THURSDAY + 1)
    assert_not Bosses::CheckDefeat.call(@boss)
    assert_nil @boss.reload.defeated_at
  end

  test "ships from different people all feed the same boss" do
    ship_damage(@user, 2_000)
    assert_not Bosses::CheckDefeat.call(@boss)
    ship_damage(users(:new_user), 1_600, on: FRIDAY + 1)
    assert Bosses::CheckDefeat.call(@boss)
  end

  test "a withdrawn, rejected or draft ship is not damage" do
    ship_damage(@user, 5_000, status: "withdrawn")
    ship_damage(@user, 5_000, status: "rejected")
    ship_damage(@user, 5_000, status: "draft")
    assert_not Bosses::CheckDefeat.call(@boss)
  end

  test "a rejected ship that is shipped again is counted once, not twice" do
    boss = make_boss(starts_on: FRIDAY + 7, hp_seconds: 5_000) # one hour is under it, the same hour twice would be over it
    project = make_project(@user)
    at = Time.utc(2026, 11, 21, 12)
    code(@user, at.to_date, 3_600)
    ship = travel_to(at) { Ships::Submit.call(project: project, attributes: ship_attrs, submit: true, now: at) }
    assert_equal 3_600, Bosses::Damage.for(boss)
    Ships::Reject.call(ship: ship, reviewer: users(:new_user), reason: "Add a demo link")
    assert_equal 0, Bosses::Damage.for(boss), "a rejected ship gives its hours back"

    again = travel_to(at) { Ships::Submit.call(project: project, attributes: ship_attrs, submit: true, now: at) }
    assert_equal 3_600, again.coded_seconds, "the same window"
    assert_equal 3_600, Bosses::Damage.for(boss)
    assert_nil boss.reload.defeated_at
  end

  test "defeated_at is never cleared when a withdrawn ship lowers the damage" do
    ship = ship_damage(@user, 5_000)
    assert Bosses::CheckDefeat.call(@boss)
    at = @boss.reload.defeated_at

    ship.update!(status: "withdrawn")
    assert_equal 0, Bosses::Damage.for(@boss)
    assert_not Bosses::CheckDefeat.call(@boss)
    assert_equal at, @boss.reload.defeated_at
  end

  test "an already defeated boss is not moved by later ships" do
    ship_damage(@user, 5_000)
    Bosses::CheckDefeat.call(@boss)
    at = @boss.reload.defeated_at
    ship_damage(@user, 5_000)
    Bosses::CheckDefeat.call(@boss)
    assert_equal at, @boss.reload.defeated_at
  end

  test "for_ship checks the boss of the week the ship was submitted in, by UTC date" do
    next_week = make_boss(starts_on: FRIDAY + 7, hp_seconds: 100)
    ship = ship_damage(@user, 5_000, on: Time.utc(2026, 11, 19, 23, 59, 59))
    Bosses::CheckDefeat.for_ship(ship)
    assert @boss.reload.defeated?
    assert_nil next_week.reload.defeated_at

    late = ship_damage(@user, 5_000, on: Time.utc(2026, 11, 20, 0, 0, 0))
    Bosses::CheckDefeat.for_ship(late)
    assert next_week.reload.defeated?
  end

  test "for_ship does nothing for a ship outside every boss week or without a submission time" do
    draft = ship_damage(@user, 5_000, status: "draft")
    assert_nothing_raised { Bosses::CheckDefeat.for_ship(draft) }
    outside = ship_damage(@user, 5_000, on: FRIDAY - 30)
    assert_nothing_raised { Bosses::CheckDefeat.for_ship(outside) }
    assert_nil @boss.reload.defeated_at
  end

  test "a failure in the check never fails the ship" do
    project = make_project(@user)
    at = Time.utc(2026, 11, 16, 12)
    code(@user, at.to_date, 7_200)
    original = Bosses::CheckDefeat.method(:call)
    Bosses::CheckDefeat.define_singleton_method(:call) { |_boss| raise "boom" }
    ship = begin
      assert_difference "Ship.count", 1 do
        travel_to(at) { Ships::Submit.call(project: project, attributes: ship_attrs, submit: true, now: at) }
      end
    ensure
      Bosses::CheckDefeat.define_singleton_method(:call, original)
    end
    assert ship.status_submitted?
    assert_nil @boss.reload.defeated_at
    assert Bosses::CheckDefeat.call(@boss), "the next check catches up"
  end

  test "approving a ship at fewer hours and withdrawing one both re-check without failing" do
    project = make_project(@user)
    at = Time.utc(2026, 11, 16, 12)
    code(@user, at.to_date, 7_200)
    ship = travel_to(at) { Ships::Submit.call(project: project, attributes: ship_attrs, submit: true, now: at) }
    assert @boss.reload.defeated?

    Ships::Approve.call(ship: ship, reviewer: users(:new_user), approved_seconds: 3_600, now: at)
    assert_equal 3_600, Bosses::Damage.for(@boss), "the approved hours are the damage now"
    assert @boss.reload.defeated?
  end
end
