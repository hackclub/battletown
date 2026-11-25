module Bosses
  # Which boss is live for a local date. Bosses never overlap, so there is at most one; `:none` between bosses,
  # before the first and after the last. Dates are UTC dates, the same rule Bosses::Damage uses to put a ship in a week, so a
  # card never shows a boss other than the one a ship just landed on.
  module Current
    module_function

    def for(date) = Boss.without_art_content.covering(date).first || :none

    # The boss live at an instant (its UTC date).
    def at(now = Time.current) = self.for(Hours::Days.today("UTC", now: now))
  end
end
