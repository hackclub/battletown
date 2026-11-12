module Shop
  # Buys one paid item with coins: one order and one coin-ledger debit, written together or not at all, under the
  # user's row lock (so two simultaneous buys cannot both spend the same coins). Idempotent on the idempotency key:
  # repeating a call returns the order already made and charges nothing more.
  #
  #   order = Shop::Purchase.call(user: user, prize_key: "tshirt", idempotency_key: key)
  #
  # Raises Shop::UnknownPrize, FreeItem, NotVerified, InsufficientCoins or KeyConflict (all friendly Shop::Error).
  class Purchase
    def self.call(...) = new(...).call

    def initialize(user:, prize_key:, idempotency_key:)
      @user = user
      @prize_key = prize_key.to_s
      @key = idempotency_key.to_s
    end

    def call
      raise KeyConflict unless @key.present? && @key.length <= Order::KEY_MAX

      @user.with_lock do
        existing = Order.find_by(user_id: @user.id, idempotency_key: @key)
        next replay(existing) if existing

        prize = Prize.find(@prize_key) or raise UnknownPrize
        raise FreeItem if prize.free_signup? || prize.coins.zero?
        raise NotVerified unless Spendable.unlocked?(@user)
        raise InsufficientCoins if Spendable.balance(@user) < prize.coins

        order = Order.create!(user: @user, prize_key: prize.key, prize_name: prize.name, coins: prize.coins, kind: "purchase",
                              idempotency_key: @key)
        Coins::Ledger.debit(user: @user, amount: prize.coins, kind: "purchase", reference: order,
                            idempotency_key: "shop:purchase:#{@key}", created_by: "shop")
        order
      end
    end

    private

    def replay(order)
      raise KeyConflict unless order.kind == "purchase" && order.prize_key == @prize_key

      order
    end
  end
end
