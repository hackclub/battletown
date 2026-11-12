require "test_helper"

class PlinkoBoardTest < ActiveSupport::TestCase
  setup { @board = Plinko::Board.current }

  test "a seed always gives the same route, one step per row, each 0 or 1" do
    path = @board.walk(123_456_789)
    assert_equal path, @board.walk(123_456_789)
    assert_equal @board.rows, path.size
    assert path.all? { |step| [ 0, 1 ].include?(step) }
    assert_not_equal (1..50).map { |seed| @board.walk(seed) }.uniq.size, 1, "different seeds should give different routes"
  end

  test "the route is pinned, so a stored seed replays the same in any Ruby version" do
    assert_equal [ 1, 0, 0, 1, 0, 0, 0, 1 ], @board.walk(0)
    assert_equal [ 1, 0, 0, 0, 0, 1, 0, 1 ], @board.walk(42)
    assert_equal [ 0, 0, 0, 1, 1, 0, 1, 0 ], @board.walk((2**61) + 5)
  end

  test "the slot is the number of right steps and always on the board" do
    1000.times do |seed|
      slot = @board.slot_for(@board.walk(seed))
      assert_includes 0..@board.rows, slot
    end
  end

  test "published odds are binomial and add up to exactly one" do
    odds = @board.odds
    assert_equal @board.slots, odds.size
    assert_equal 1, odds.sum
    assert_equal Rational(1, 256), odds.first
    assert_equal Rational(70, 256), odds[4]
    assert_equal odds, odds.reverse, "a fair board is symmetric"
  end

  test "over many seeds the slots land where the published odds say" do
    runs = 30_000
    counts = Array.new(@board.slots, 0)
    runs.times { |seed| counts[@board.slot_for(@board.walk(seed * 7919 + 13))] += 1 }

    @board.odds.each_with_index do |chance, slot|
      assert_in_delta chance.to_f, counts[slot].to_f / runs, 0.01, "slot #{slot} lands #{counts[slot]} of #{runs} times"
    end
    average = @board.slot_points.each_with_index.sum { |points, slot| points * counts[slot] }.to_f / runs
    assert_in_delta @board.expected_points.to_f, average, 4
  end

  test "random seeds from SecureRandom fit the bigint column" do
    100.times { assert_includes 0...(1 << 62), Plinko::Board.random_seed }
  end

  test "the configured points table has a value for every slot and every ball scores" do
    config = Plinko::Config.current
    assert_equal config.rows + 1, config.slot_points.size
    assert config.slot_points.all?(&:positive?)
    assert_raises(ArgumentError) { Plinko::Config.from_hash(Rails.application.config_for(:game).fetch(:plinko).merge(slot_points: [ 1, 2 ])) }
  end
end
