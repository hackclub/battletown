require "test_helper"
require_relative "../support/bosses_helper"

class BossTest < ActiveSupport::TestCase
  include BossesHelper

  # A failed statement aborts the surrounding test transaction, so each attempt runs in a savepoint.
  def assert_db_rejects(**attrs)
    columns = { name: "Boss", art_key: "placeholder", starts_on: FRIDAY, ends_on: THURSDAY, hp_seconds: 3600,
                created_at: Time.current, updated_at: Time.current }.merge(attrs)
    assert_raises(ActiveRecord::StatementInvalid, "#{attrs.inspect} should be rejected by the database") do
      Boss.transaction(requires_new: true) { Boss.insert_all!([ columns ]) }
    end
  end

  def build(**attrs)
    Boss.new({ name: "Boss", art_key: "placeholder", starts_on: FRIDAY, ends_on: THURSDAY, hp_seconds: 3600 }.merge(attrs))
  end

  test "a valid boss saves and exposes its art path and range" do
    boss = make_boss
    assert_equal "bosses/placeholder.webp", boss.art_path
    assert_equal FRIDAY..THURSDAY, boss.range
    assert_not boss.defeated?
    assert File.exist?(Rails.root.join("app/assets/images/#{boss.art_path}")), "every art key has an asset"
    assert_equal Boss::ART_KEYS.sort, Boss::ARTS.keys.sort
  end

  test "every art key has an asset on disk" do
    Boss::ART_KEYS.each { |key| assert File.exist?(Rails.root.join("app/assets/images/bosses/#{key}.webp")), key }
  end

  test "model validations" do
    assert build.valid?
    assert_not build(name: "").valid?
    assert_not build(name: "   ").valid?
    assert_not build(name: "x" * 61).valid?
    assert build(name: "x" * 60).valid?
    assert_not build(art_key: "../../secret").valid?
    assert_not build(art_key: "nope").valid?
    assert_not build(starts_on: nil).valid?
    assert_not build(ends_on: FRIDAY - 1).valid?
    assert build(ends_on: FRIDAY).valid?, "a one-day boss is fine"
    assert_not build(hp_seconds: 0).valid?
    assert_not build(hp_seconds: -1).valid?
    assert_not build(hp_seconds: 1.5).valid?
    assert_not build(hp_seconds: Boss::MAX_HP_SECONDS + 1).valid?
    assert build(hp_seconds: 1).valid?
  end

  test "the name is squished" do
    assert_equal "Big Bad Boss", build(name: "  Big   Bad\nBoss ").tap(&:valid?).name
  end

  test "hp_hours converts to seconds and back" do
    boss = build(hp_seconds: nil)
    boss.hp_hours = "500"
    assert_equal 1_800_000, boss.hp_seconds
    assert_equal 500, boss.hp_hours
    boss.hp_hours = "1.5"
    assert_equal 5_400, boss.hp_seconds
    assert_equal 1.5, boss.hp_hours
    boss.hp_hours = "lots"
    assert_nil boss.hp_seconds
    assert_not boss.valid?
  end

  test "starts_on must be unique and overlapping weeks are refused" do
    make_boss
    assert_not build.valid?
    assert_not build(starts_on: FRIDAY + 3, ends_on: FRIDAY + 9).valid?, "overlaps the tail"
    assert_not build(starts_on: FRIDAY - 3, ends_on: FRIDAY).valid?, "overlaps the head on one shared day"
    assert_not build(starts_on: FRIDAY + 1, ends_on: FRIDAY + 2).valid?, "inside"
    assert build(starts_on: THURSDAY + 1, ends_on: THURSDAY + 7).valid?, "the next week is fine"
    assert build(starts_on: FRIDAY - 7, ends_on: FRIDAY - 1).valid?, "the week before is fine"
  end

  test "the database rejects overlapping ranges and a duplicate start even without validations" do
    make_boss
    assert_db_rejects(starts_on: FRIDAY + 6, ends_on: FRIDAY + 12)
    assert_db_rejects(starts_on: FRIDAY, ends_on: FRIDAY)
    assert_db_rejects(starts_on: FRIDAY - 2, ends_on: FRIDAY)
    assert_nothing_raised { Boss.transaction(requires_new: true) { Boss.insert_all!([ { name: "Next", art_key: "placeholder", starts_on: FRIDAY + 7, ends_on: FRIDAY + 13, hp_seconds: 60, created_at: Time.current, updated_at: Time.current } ]) } }
  end

  test "the database rejects values the model would" do
    assert_db_rejects(name: "")
    assert_db_rejects(name: "   ")
    assert_db_rejects(name: "x" * 61)
    assert_db_rejects(art_key: "Has Spaces")
    assert_db_rejects(art_key: "../x")
    assert_db_rejects(art_key: "")
    assert_db_rejects(ends_on: FRIDAY - 1)
    assert_db_rejects(hp_seconds: 0)
    assert_db_rejects(hp_seconds: -5)
    assert_db_rejects(hp_seconds: Boss::MAX_HP_SECONDS + 1)
    assert_db_rejects(name: nil)
    assert_db_rejects(starts_on: nil)
  end

  test "health is editable before the boss starts and locked from its first day" do
    boss = make_boss(starts_on: Date.new(2026, 11, 20))

    travel_to Time.utc(2026, 11, 18, 12) do
      assert_not boss.started?
      assert boss.update(hp_hours: 100)
      assert_equal 360_000, boss.hp_seconds
    end

    # Friday 20 Nov has begun for the earliest time zone (UTC+14) at 10:00 UTC on Thursday the 19th.
    travel_to Time.utc(2026, 11, 19, 10) do
      assert boss.started?
      assert_not boss.update(hp_hours: 5)
      assert_includes boss.errors.full_messages.join, "can't change once the boss has started"
      assert_equal 360_000, boss.reload.hp_seconds
      assert boss.update(name: "Renamed", hp_hours: 100), "the same health is not a change"
    end
  end

  test "dates are not editable" do
    boss = make_boss
    assert_not boss.update(ends_on: boss.ends_on + 1)
    assert_not boss.update(starts_on: boss.starts_on - 1)
  end

  test "defeated_at cannot be cleared or moved once set" do
    boss = make_boss
    assert boss.update(defeated_at: Time.zone.parse("2026-11-14 12:00"))
    assert_not boss.update(defeated_at: nil)
    assert_not boss.update(defeated_at: Time.zone.parse("2026-11-15 12:00"))
    assert_equal Time.zone.parse("2026-11-14 12:00"), boss.reload.defeated_at
  end

  test "covering finds the boss whose range includes the date, ends inclusive" do
    boss = make_boss
    assert_equal [ boss ], Boss.covering(FRIDAY).to_a
    assert_equal [ boss ], Boss.covering(THURSDAY).to_a
    assert_empty Boss.covering(FRIDAY - 1)
    assert_empty Boss.covering(THURSDAY + 1)
  end

  test "bosses reference no user, so nothing about a person is stored" do
    assert_empty Boss.column_names.grep(/user/)
    assert_empty ActiveRecord::Base.connection.foreign_keys("bosses")
  end
end
