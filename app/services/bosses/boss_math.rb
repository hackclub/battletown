module Bosses
  # The boss arithmetic, on plain integers only: no database, no clock. `sum` and `damage` are seconds of coded time,
  # `hp` is the boss's health in seconds (always > 0).
  #
  # Percentages are integer FLOORS, so a bar never claims progress it has not made: 36 seconds on a 500 hour boss is
  # 0%, one second short of the health is 99%, and 100% only ever means the boss is down.
  module BossMath
    module_function

    # The damage a ledger sum represents: never negative (corrections can only bring a week down to zero).
    def damage(sum) = [ sum, 0 ].max

    # Damage dealt, as a whole percent of the health, 0 to 100.
    def percent(damage, hp) = [ damage * 100 / hp, 100 ].min

    # Damage dealt as a fraction of the health, 0.0 to 1.0 (never above, however big the overkill).
    def ratio(damage, hp) = [ damage.to_f / hp, 1.0 ].min

    # Health left, in seconds.
    def remaining(damage, hp) = [ hp - damage, 0 ].max

    # Damage past the health, in seconds. Shown, never carried over to another boss.
    def overkill(damage, hp) = [ damage - hp, 0 ].max

    def defeated?(damage, hp) = damage >= hp
  end
end
