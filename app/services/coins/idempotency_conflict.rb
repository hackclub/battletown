module Coins
  # The same idempotency key was reused for a different kind or amount: a caller bug, never silently ignored.
  class IdempotencyConflict < StandardError; end
end
