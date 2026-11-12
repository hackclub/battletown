module Bosses
  # Which boss is live for a local date. Bosses never overlap, so there is at most one; `:none` between bosses,
  # before the first and after the last. Dates are local to the viewer (see Hours::Days).
  module Current
    module_function

    def for(date) = Boss.covering(date).first || :none

    def for_user(user, now: Time.current) = self.for(Hours::Days.today(user, now: now))
  end
end
