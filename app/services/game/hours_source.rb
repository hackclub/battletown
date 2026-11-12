module Game
  # Where daily coded seconds come from. The only interface the game depends on is
  #
  #   source.seconds_by_date(user, range) # => { Date => Integer seconds }, local dates, missing dates mean 0
  #
  # which is what `Hours::Totals` (the hours ledger) provides. Wiring: `Game::HoursSource.current` returns
  # `Hours::Totals` once that class exists; tests and other callers can pass any object with that one method as
  # `source:` to Game::Settle and Coins::ApproveShip, or set `Game::HoursSource.current = ...` explicitly.
  module HoursSource
    class Missing < StandardError; end

    class << self
      attr_writer :current

      def current
        @current ||= resolve
      end

      def reset!
        @current = nil
      end

      private

      def resolve
        return "Hours::Totals".constantize if Object.const_defined?("Hours::Totals")

        raise Missing, "no hours source: Hours::Totals is not available; pass source: or set Game::HoursSource.current"
      end
    end
  end
end
