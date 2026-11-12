module Plinko
  # Drops one ball for a player: the server decides where it lands, so the browser can only animate the result.
  #
  #   Plinko::Drop.call(user:, idempotency_key: "...")  # => Result(drop:, replayed:, path:)
  #
  # - Needs a ball (Plinko::Balls); otherwise raises NoBalls.
  # - Takes a Postgres advisory lock for the player (held to the end of the transaction), so two requests at once can
  #   never spend the same ball: the second one waits, then sees the first drop and its smaller bank.
  # - The slot comes from a random seed (Plinko::Board.walk); the seed is stored, so the route can be replayed.
  # - `idempotency_key` (the browser makes a fresh one per click) makes a repeated request a no-op: it returns the
  #   drop that key already made, with replayed: true, and uses no second ball.
  # - Never touches coins (nothing here, or anywhere in Plinko, writes the coins ledger).
  class Drop
    class Error < StandardError; end
    class NoBalls < Error; end
    class InvalidKey < Error; end

    Result = Data.define(:drop, :replayed, :path)

    LOCK_NAMESPACE = 710_001 # first argument of the two-integer advisory lock; the second is the user's id

    def self.call(...) = new(...).call

    def initialize(user:, idempotency_key:, now: Time.current, seed: nil, board: Board.current, config: Config.current)
      @user = user
      @key = idempotency_key.to_s
      @now = now
      @seed = seed
      @board = board
      @config = config
    end

    def call
      raise InvalidKey, "bad idempotency key" unless @key.match?(PlinkoDrop::KEY_FORMAT)

      PlinkoDrop.transaction do
        lock_player
        existing = PlinkoDrop.find_by(user_id: @user.id, idempotency_key: @key)
        next Result.new(drop: existing, replayed: true, path: @board.walk(existing.seed)) if existing

        raise NoBalls, "no balls to drop" unless Balls.for(@user, now: @now, config: @config).any?

        seed = @seed || Board.random_seed
        path = @board.walk(seed)
        slot = @board.slot_for(path)
        drop = PlinkoDrop.create!(user: @user, dropped_at: @now, local_date: Hours::Days.today(@user, now: @now), slot: slot,
                                  points: @board.points_for(slot), seed: seed, idempotency_key: @key)
        Result.new(drop: drop, replayed: false, path: path)
      end
    end

    private

    def lock_player
      sql = ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", LOCK_NAMESPACE, @user.id % (2**31) ])
      ApplicationRecord.connection.execute(sql)
    end
  end
end
