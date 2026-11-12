module Coins
  # A debit that would take a user's balance below zero. Coins are never negative.
  class InsufficientBalance < StandardError; end
end
