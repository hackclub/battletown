module Orders
  # Placing an order from the shop: Shop::Purchase behind the cap on orders waiting for the team (config `max_open_requested`,
  # default 5). It counts what the buyer sees as "Requested" (requested plus on hold) and is checked under the user's row lock,
  # so two simultaneous clicks cannot both pass it. A repeat of an order that already exists (same idempotency key) is never
  # refused: it returns that order, charging nothing more. Raises Orders::TooManyOpen, plus everything Shop::Purchase raises.
  class Place
    def self.call(...) = new(...).call

    def initialize(user:, prize_key:, idempotency_key:)
      @user = user
      @prize_key = prize_key
      @key = idempotency_key
    end

    def call
      @user.with_lock do
        raise TooManyOpen if new_order? && waiting_count >= Config.current.max_open_requested

        Shop::Purchase.call(user: @user, prize_key: @prize_key, idempotency_key: @key)
      end
    end

    private

    def new_order? = !Order.exists?(user_id: @user.id, idempotency_key: @key.to_s)

    def waiting_count = Order.where(user_id: @user.id, kind: "purchase", status: %w[requested on_hold]).count
  end
end
