module Shop
  # Every shop failure is one of these, with a message that is fine to show to the person (no ids, no internals).
  class Error < StandardError; end

  class NotVerified < Error
    def initialize(msg = "Coins unlock when you verify your identity with Hack Club.") = super
  end

  class InsufficientCoins < Error
    def initialize(msg = "You don't have enough coins for that yet.") = super
  end

  class UnknownPrize < Error
    def initialize(msg = "That item isn't in the shop.") = super
  end

  class FreeItem < Error
    def initialize(msg = "That one is free: claim it from the shop page instead of buying it.") = super
  end

  class AlreadyClaimed < Error
    def initialize(msg = "You've already claimed your free sticker.") = super
  end

  class NotCancellable < Error
    def initialize(msg = "That order can't be cancelled any more.") = super
  end

  class NotFulfillable < Error
    def initialize(msg = "That order can't be marked fulfilled.") = super
  end

  # The same idempotency key was reused for a different request.
  class KeyConflict < Error
    def initialize(msg = "That request was already used for something else. Please try again.") = super
  end
end
