module Bosses
  # The damage a boss has taken: the sum of ALL users' coded seconds on the local dates inside its week, straight from
  # the hours ledger (raw coded time: no bonus, no deflation, no approval). Floored at zero. Aggregate only.
  module Damage
    module_function

    def for(boss) = BossMath.damage(Hours::Totals.seconds_in_range(boss.starts_on..boss.ends_on))
  end
end
