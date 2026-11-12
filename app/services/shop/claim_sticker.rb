module Shop
  # The free signup sticker: one per person, no coins, allowed even before identity is verified. Calling it again
  # raises Shop::AlreadyClaimed (a unique index backs this up, so a race cannot make two).
  class ClaimSticker
    def self.call(...) = new(...).call

    def initialize(user:)
      @user = user
    end

    def call
      prize = Prize.free_signup or raise ItemUnavailable # none on offer: staff archived it
      @user.with_lock do
        raise AlreadyClaimed if Order.exists?(user_id: @user.id, kind: "signup_sticker")

        Order.create!(user: @user, prize_key: prize.key, prize_name: prize.name, coins: 0, kind: "signup_sticker",
                      idempotency_key: "signup_sticker")
      end
    rescue ActiveRecord::RecordNotUnique
      raise AlreadyClaimed
    end
  end
end
