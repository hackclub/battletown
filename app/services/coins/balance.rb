module Coins
  # A user's coin balance: the sum of their ledger rows. The Ledger refuses any debit that would take it below zero.
  module Balance
    module_function

    def total(user)
      CoinTransaction.where(user_id: user.id).sum(:amount)
    end
  end
end
