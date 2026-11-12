module Quests
  # The copy and limits of one goal. `target_range` is nil for a goal that is a single step.
  GoalCopy = Data.define(:key, :title, :description, :unit, :target_range, :default_target) do
    def targeted? = !target_range.nil?

    # "Code on 3 different days", with the quest's own number filled in.
    def title_for(target, minutes) = format_copy(title, target, minutes)

    def description_for(target, minutes) = format_copy(description, target, minutes)

    private

    def format_copy(text, target, minutes) = format(text, target: target, minutes: minutes)
  end

  # Tunables and copy from config/game.yml under `quests:`. Read through `Quests::Config.current`; `reset!` and
  # `from_hash` let tests build a variant. Numbers are converted to integers once, here.
  Config = Data.define(:default_reward_coins, :max_reward_coins, :allowed_goals, :grace_days, :goals) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:game).fetch(:quests))
    end

    def self.reset!
      @current = nil
    end

    def self.from_hash(raw)
      goals = raw.fetch(:goals).to_h { |key, goal| [ key.to_s, build_goal(key.to_s, goal) ] }
      allowed = Array(raw.fetch(:allowed_goals)).map(&:to_s)
      default = integer(raw.fetch(:default_reward_coins), "quests.default_reward_coins", 1)
      max = integer(raw.fetch(:max_reward_coins), "quests.max_reward_coins", 1)
      raise ArgumentError, "game.yml: quests.max_reward_coins can be at most #{Quest::REWARD_CEILING}" if max > Quest::REWARD_CEILING
      raise ArgumentError, "game.yml: quests.default_reward_coins must not be above max_reward_coins" if default > max
      raise ArgumentError, "game.yml: quests.allowed_goals needs at least one goal" if allowed.empty?
      unknown = (allowed + goals.keys) - Goals::KEYS
      raise ArgumentError, "game.yml: quests has unknown goals #{unknown.join(', ')}" if unknown.any?
      raise ArgumentError, "game.yml: every allowed quest goal needs copy under quests.goals" unless (allowed - goals.keys).empty?

      new(default_reward_coins: default, max_reward_coins: max, allowed_goals: allowed.freeze,
          grace_days: integer(raw.fetch(:evaluate_grace_days), "quests.evaluate_grace_days", 0), goals: goals.freeze)
    end

    def self.build_goal(key, raw)
      range = raw[:target]
      min = max = nil
      if range
        min = integer(range.fetch(:min), "quests.goals.#{key}.target.min", 1)
        max = integer(range.fetch(:max), "quests.goals.#{key}.target.max", min)
      end
      default = range ? integer(range.fetch(:default), "quests.goals.#{key}.target.default", min) : nil
      raise ArgumentError, "game.yml: quests.goals.#{key}.target.default is out of range" if default && default > max

      GoalCopy.new(key: key, title: raw.fetch(:title).to_s, description: raw.fetch(:description).to_s, unit: raw[:unit]&.to_s,
               target_range: range ? (min..max) : nil, default_target: default)
    end

    def self.integer(value, name, minimum)
      raise ArgumentError, "game.yml: #{name} must be an integer of at least #{minimum}" unless value.is_a?(Integer) && value >= minimum

      value
    end
    private_class_method :build_goal, :integer

    def goal(key) = goals.fetch(key.to_s)

    # The menu the admin form offers, in config order.
    def menu = allowed_goals.map { |key| goal(key) }

    def quick_minutes = Game::Config.current.quick_seconds / 60
  end
end
