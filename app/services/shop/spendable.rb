module Shop
  # What a person can spend right now. Coins are earned by anyone, but spending is locked until `User#can_spend_coins?`
  # (identity verified with Hack Club, plus eligibility and a fresh verification while the `eligibility_gate` flag is
  # on), so `balance` is the whole coin balance when they can spend and 0 otherwise. Coding is never blocked by this.
  # Other features that need "can this person pay for it" should ask here, not Coins::Balance.
  module Spendable
    module_function

    def balance(user) = unlocked?(user) ? Coins::Balance.total(user) : 0

    def unlocked?(user) = user.can_spend_coins?

    def locked?(user) = !unlocked?(user)

    # Raises the friendly error for whatever is in the way (nothing when they can spend), so the purchase and the
    # confirmation page can never disagree with the notes.
    def check!(user)
      case user.spend_state
      when :unverified then raise NotVerified
      when :stale then raise NeedsRecheck
      when :not_eligible then raise NotEligible
      end
    end
  end
end
