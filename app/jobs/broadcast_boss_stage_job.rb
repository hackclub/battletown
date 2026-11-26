# The trailing broadcast of Bosses::Live: when changes arrived while the last broadcast was less than 5 seconds old, one more goes out a
# few seconds later with everything they changed. Runs on the in-process Active Job adapter (production has no queue); if the process
# goes away first, nothing is lost for good: the pages reconcile on their own and the next change broadcasts again.
class BroadcastBossStageJob < ApplicationJob
  queue_as :default

  def perform(boss_id) = Bosses::Live.flush(boss_id)
end
