module Shop
  # Buys one paid item with coins: one order and one coin-ledger debit, written together or not at all, under the
  # user's row lock (so two simultaneous buys cannot both spend the same coins). Idempotent on the idempotency key:
  # repeating a call returns the order already made and charges nothing more.
  #
  #   order = Shop::Purchase.call(user: user, prize_key: "tshirt", idempotency_key: key)
  #
  # Raises Shop::UnknownPrize, ItemUnavailable (archived by staff), FreeItem, PriceChanged (the price differs from `expected_coins`), NotVerified, NotEligible, NeedsRecheck (the last two only while the
  # `eligibility_gate` flag is on), InsufficientCoins or KeyConflict (all friendly Shop::Error).
  class Purchase
    def self.call(...) = new(...).call

    # The key the free signup sticker is stored under; a purchase may not use it (it would block that person's sticker for good).
    RESERVED_KEYS = %w[signup_sticker].freeze

    # `expected_coins` is the price the buyer was shown (the confirm form sends it back); when given, a different current price
    # is refused with PriceChanged instead of charging it.
    def initialize(user:, prize_key:, idempotency_key:, expected_coins: nil)
      @user = user
      @expected_coins = expected_coins
      @prize_key = prize_key.to_s
      @key = idempotency_key.to_s
    end

    def call
      raise KeyConflict unless @key.present? && @key.length <= Order::KEY_MAX && RESERVED_KEYS.exclude?(@key)

      @user.with_lock do
        existing = Order.find_by(user_id: @user.id, idempotency_key: @key)
        next replay(existing) if existing

        Prize.reload! # the price and the archived flag are read again now that the lock is held (the request may have loaded them earlier)
        prize = Prize.find(@prize_key) or raise UnknownPrize
        raise ItemUnavailable unless prize.active?
        raise FreeItem if prize.free_signup? || prize.coins.zero?
        raise PriceChanged if @expected_coins && @expected_coins != prize.coins
        Spendable.check!(@user)
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
