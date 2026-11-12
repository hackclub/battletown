module Plinko
  # The board: where a ball goes and what the slots pay. Pure (no database, no clock).
  #
  # The server draws a random seed (SecureRandom, in Plinko::Drop) and everything else follows from it, so a drop can
  # be replayed from the seed alone: `walk(seed)` is the route (one step per row of pegs, 0 = left, 1 = right), and the
  # slot is the number of right steps. Each step takes the top bit of one SplitMix64 output (a small, well-known
  # generator with a fixed definition, so a stored seed gives the same route in any Ruby version). Every peg is a fair
  # coin, so slot k has chance C(rows, k) / 2^rows (`odds`).
  class Board
    MASK = (1 << 64) - 1
    SEED_LIMIT = 1 << 62 # seeds fit a signed bigint

    def self.current = new(Config.current)

    def self.random_seed = SecureRandom.random_number(SEED_LIMIT)

    def initialize(config)
      @rows = config.rows
      @slot_points = config.slot_points
    end

    attr_reader :rows, :slot_points

    def slots = rows + 1

    # The route for a seed: an array of `rows` zeros (left) and ones (right).
    def walk(seed)
      state = Integer(seed) & MASK
      Array.new(rows) do
        state = (state + 0x9E3779B97F4A7C15) & MASK
        mixed = state
        mixed = ((mixed ^ (mixed >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        mixed = ((mixed ^ (mixed >> 27)) * 0x94D049BB133111EB) & MASK
        (mixed ^ (mixed >> 31)) >> 63
      end
    end

    def slot_for(path) = path.sum

    def points_for(slot) = slot_points.fetch(slot)

    # Chance of each slot, as fractions of 1 (they add up to exactly 1).
    def odds = Array.new(slots) { |slot| Rational(binomial(rows, slot), 2**rows) }

    # The average points a ball is worth.
    def expected_points = odds.each_with_index.sum { |chance, slot| chance * slot_points[slot] }

    private

    def binomial(n, k) = (1..k).reduce(1) { |acc, i| acc * (n - i + 1) / i }
  end
end
