module Shop
  # Every shop failure is one of these, with a message that is fine to show to the person (no ids, no internals).
  class Error < StandardError; end

  class NotVerified < Error
    def initialize(msg = "Coins unlock when you verify your identity with Hack Club.") = super
  end

  # Verified but not eligible for Hack Club YSWS programs (flag `eligibility_gate`). Kind, and never says why.
  class NotEligible < Error
    TEXT = "Prizes are only available to people who qualify for Hack Club YSWS programs. Your account does not qualify yet.".freeze

    def initialize(msg = "#{TEXT} #{Eligibility::Config.current.help_line}") = super
  end

  # Verified, but the sign-in copy of the verification is older than the maximum age (flag `eligibility_gate`).
  class NeedsRecheck < Error
    TEXT = "Sign in again to refresh your verification.".freeze

    def initialize(msg = TEXT) = super
  end

  class InsufficientCoins < Error
    def initialize(msg = "You don't have enough coins for that yet.") = super
  end

  class UnknownPrize < Error
    def initialize(msg = "That item isn't in the shop.") = super
  end

  # The item exists but staff have archived it: it can no longer be bought (people who already ordered it keep their order).
  class ItemUnavailable < Error
    def initialize(msg = "That item isn't in the shop any more.") = super
  end

  class FreeItem < Error
    def initialize(msg = "That one is free: claim it from the shop page instead of buying it.") = super
  end

  class AlreadyClaimed < Error
    def initialize(msg = "You've already claimed your free sticker.") = super
  end

  # The same idempotency key was reused for a different request.
  class PriceChanged < Error
    def initialize(msg = "The price changed while you were looking. Check the new price and place the order again.") = super
  end

  class KeyConflict < Error
    def initialize(msg = "That request was already used for something else. Please try again.") = super
  end
end
