require "test_helper"
require "rake"

class Bosses::SeedTest < ActiveSupport::TestCase
  test "creates the four launch weeks, Friday to Thursday, with placeholder names and 500 hours" do
    assert_equal 4, Bosses::Seed.call

    bosses = Boss.chronological.to_a
    assert_equal [ "Boss 1", "Boss 2", "Boss 3", "Boss 4" ], bosses.map(&:name)
    assert_equal [ Date.new(2026, 11, 13), Date.new(2026, 11, 20), Date.new(2026, 11, 27), Date.new(2026, 12, 4) ], bosses.map(&:starts_on)
    assert_equal [ Date.new(2026, 11, 19), Date.new(2026, 11, 26), Date.new(2026, 12, 3), Date.new(2026, 12, 10) ], bosses.map(&:ends_on)
    assert(bosses.all? { |boss| boss.starts_on.friday? && boss.ends_on.thursday? })
    assert_equal [ 1_800_000 ] * 4, bosses.map(&:hp_seconds)
    assert_equal [ "placeholder" ], bosses.map(&:art_key).uniq
    assert_equal 28, (bosses.last.ends_on - bosses.first.starts_on).to_i + 1
  end

  test "is idempotent and never overwrites an edited boss" do
    Bosses::Seed.call
    Boss.find_by!(starts_on: Date.new(2026, 11, 13)).update!(name: "The Great Compiler", hp_seconds: 720_000)

    assert_no_difference "Boss.count" do
      assert_equal 0, Bosses::Seed.call
    end
    boss = Boss.find_by!(starts_on: Date.new(2026, 11, 13))
    assert_equal "The Great Compiler", boss.name
    assert_equal 720_000, boss.hp_seconds
  end

  test "fills in only the missing weeks" do
    Bosses::Seed.call
    Boss.find_by!(starts_on: Date.new(2026, 11, 27)).destroy!
    assert_equal 1, Bosses::Seed.call
    assert_equal 4, Boss.count
  end

  test "the rake task and db/seeds.rb both seed, repeatably" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("bosses:seed")
    2.times do
      Rake::Task["bosses:seed"].reenable
      assert_output(/bosses:seed created=\d total=4/) { Rake::Task["bosses:seed"].invoke }
    end
    assert_equal 4, Boss.count
    assert_no_difference "Boss.count" do
      load Rails.root.join("db/seeds.rb")
    end
  end
end
