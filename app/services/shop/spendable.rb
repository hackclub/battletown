module Shop
  # What a person can spend right now. Coins are earned by anyone, but spending is locked until their identity is
  # verified with Hack Club, so `balance` is the whole coin balance when verified and 0 otherwise. Coding is never
  # blocked by this. Other features that need "can this person pay for it" should ask here, not Coins::Balance.
  module Spendable
    module_function

    def balance(user) = unlocked?(user) ? Coins::Balance.total(user) : 0

    def unlocked?(user) = user.verification_verified?

    def locked?(user) = !unlocked?(user)
  end
end
