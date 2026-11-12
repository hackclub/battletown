module Orders
  # Placing an order from the shop: Shop::Purchase behind the cap on orders waiting for the team (config `max_open_requested`,
  # default 5). It counts what the buyer sees as "Requested" (requested plus on hold) and is checked under the user's row lock,
  # so two simultaneous clicks cannot both pass it. A repeat of an order that already exists (same idempotency key) is never
  # refused: it returns that order, charging nothing more. Raises Orders::TooManyOpen, plus everything Shop::Purchase raises.
  #
  # With `address_required: true` (a physical item) the order is made together with its shipping address, in the same transaction:
  # `address_id` must be an address in the buyer's own live offer for this draft (the idempotency key); see Orders::AttachAddress.
  # Either both rows exist afterwards or neither does (a missing, stale or tampered address id rolls the whole order back, coins
  # included). A repeat of an order that exists never reads the address again.
  class Place
    def self.call(...) = new(...).call

    def initialize(user:, prize_key:, idempotency_key:, address_id: nil, address_required: false)
      @user = user
      @prize_key = prize_key
      @key = idempotency_key
      @address_id = address_id
      @address_required = address_required
    end

    def call
      @user.with_lock do
        fresh = new_order?
        raise TooManyOpen if fresh && waiting_count >= Config.current.max_open_requested

        order = Shop::Purchase.call(user: @user, prize_key: @prize_key, idempotency_key: @key)
        AttachAddress.for_new_order!(order: order, user: @user, draft_key: @key.to_s, address_id: @address_id) if fresh && @address_required
        order
      end
    end

    private

    def new_order? = !Order.exists?(user_id: @user.id, idempotency_key: @key.to_s)

    def waiting_count = Order.where(user_id: @user.id, kind: "purchase", status: %w[requested on_hold]).count
  end
end
