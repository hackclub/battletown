module Quests
  # Records who has completed a quest, once. Safe to call as often as you like (the dashboard calls it on every load,
  # `rake quests:evaluate` for everyone, and the approval subscriber right after a ship is approved).
  #
  # For one user it looks at the quests whose week has begun in THEIR local date and that ended no more than
  # `evaluate_grace_days` ago (late-syncing hours still count), skips the ones already recorded and the ones that ended
  # before the user signed up, and asks the goal checker (Quests::Goals). A goal that holds is saved as a
  # QuestCompletion stamped with the first moment it held (from the ledger, not "now"); two callers at once write one
  # row (the unique index decides). Then Quests::Payout pays whatever is waiting for an approved ship.
  #
  # Off while the Flipper flag `quests` is off: it reads and writes nothing.
  module Evaluate
    module_function

    # Returns the QuestCompletions recorded by THIS call.
    def call(user, now: Time.current)
      return [] unless Features.enabled?(:quests)

      recorded = open_quests(user, now).filter_map { |quest| record(user, quest, now) }
      Payout.call(user, now: now)
      recorded
    end

    # Everyone who could have something to record: onboarded users, one at a time so one failure never stops the rest.
    # Returns { users:, completions:, errors: }.
    def all(now: Time.current)
      counts = { users: 0, completions: 0, errors: 0 }
      return counts unless Features.enabled?(:quests)

      User.where.not(onboarded_at: nil).find_each do |user|
        counts[:completions] += call(user, now: now).size
        counts[:users] += 1
      rescue StandardError => error
        counts[:errors] += 1
        Rails.logger.error("quests evaluate failed error=#{error.class}")
      end
      counts
    end

    def open_quests(user, now)
      today = Hours::Days.today(user, now: now)
      done = QuestCompletion.where(user_id: user.id).select(:quest_id)
      Quest.where(starts_on: ..today, ends_on: [ today - Config.current.grace_days, Hours::Days.first_counted_date(user) ].max..)
           .where.not(id: done).chronological.to_a
    end

    def record(user, quest, now)
      progress = Goals.check(user, quest)
      return unless progress.complete?

      completion = QuestCompletion.create_or_find_by!(user_id: user.id, quest_id: quest.id) do |row|
        row.completed_at = [ progress.completed_at, now ].min
      end
      completion if completion.previously_new_record?
    end
    private_class_method :open_quests, :record
  end
end
