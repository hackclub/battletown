module Shop
  # The free signup sticker: one per person, no coins, allowed even before identity is verified. Calling it again
  # raises Shop::AlreadyClaimed (a unique index backs this up, so a race cannot make two). With `address_required: true` (a
  # physical sticker) it is claimed together with its shipping address, in one transaction, exactly like Orders::Place
  # (draft key "sticker").
  class ClaimSticker
    def self.call(...) = new(...).call

    def initialize(user:, address_id: nil, address_required: false)
      @user = user
      @address_id = address_id
      @address_required = address_required
    end

    def call
      prize = Prize.free_signup or raise ItemUnavailable # none on offer: staff archived it
      @user.with_lock do
        raise AlreadyClaimed if Order.exists?(user_id: @user.id, kind: "signup_sticker")

        order = Order.create!(user: @user, prize_key: prize.key, prize_name: prize.name, coins: 0, kind: "signup_sticker",
                              idempotency_key: "signup_sticker")
        Orders::AttachAddress.for_new_order!(order: order, user: @user, draft_key: "sticker", address_id: @address_id) if @address_required
        order
      end
    rescue ActiveRecord::RecordNotUnique
      raise AlreadyClaimed
    end
  end
end
