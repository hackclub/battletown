module Quests
  # What the dashboard's quest card shows, as plain values and ready-made sentences (the view has no rules of its own).
  #
  #   card = Quests::Presenter.new(user: current_user)
  #   render "quests/card", card: card if card.visible?
  #
  # Only the viewer's own progress appears: no other person's name, hours or rank. The card is for this week's quest; if
  # this week has none, it still shows a finished quest from before whose reward is waiting for an approved ship, so the
  # promise is never lost. A quest the viewer did not finish is simply not shown once its week is over (no "you failed").
  # Build it only while the `quests` flag is on (the dashboard does; with the flag off nothing is read).
  class Presenter
    STATES = %i[in_progress pending paid].freeze

    attr_reader :user, :now

    def initialize(user:, now: Time.current)
      @user = user
      @now = now
    end

    def visible? = !quest.nil?

    # in_progress, pending (done, the reward waits for an approved ship) or paid.
    def state
      return :paid if completion&.paid?

      completion ? :pending : :in_progress
    end

    def title = quest.title

    def description = quest.description

    def reward_text = "#{quest.reward_coins} #{'coin'.pluralize(quest.reward_coins)}"

    def chip_text = { in_progress: "In progress", pending: "Done", paid: "Paid" }.fetch(state)

    def chip_variant = { in_progress: "badge--primary", pending: "badge--success", paid: "badge--success" }.fetch(state)

    def target = progress.target

    def progress_value = progress.current

    # "2 of 3 days" for a goal that counts, "Not yet" / "Done" for a single step.
    def progress_text
      unit = quest.goal&.unit
      return (progress.current >= target ? "Done" : "Not yet") unless unit

      "#{progress.current} of #{target} #{unit.pluralize(target)}"
    end

    def message
      case state
      when :pending then "Quest done! Your #{reward_text} arrive with your next approved ship."
      when :paid then "Quest done! Your #{reward_text} were paid with your approved ship."
      else "Finish it and your #{reward_text} arrive with your next approved ship."
      end
    end

    def days_left_text
      return unless state == :in_progress

      left = (quest.ends_on - today).to_i + 1
      "#{left} #{'day'.pluralize(left)} left (this boss week ends #{quest.ends_on.strftime('%A')})"
    end

    def today = @today ||= Hours::Days.today(user, now: now)

    private

    def quest
      return @quest if defined?(@quest)

      @quest = Quest.for_date(today) || waiting_completion&.quest
    end

    def completion
      return @completion if defined?(@completion)

      @completion = quest && QuestCompletion.find_by(user_id: user.id, quest_id: quest.id)
    end

    # A quest from an earlier week that the user finished and that has not been paid yet.
    def waiting_completion
      QuestCompletion.pending.where(user_id: user.id).includes(:quest).order(completed_at: :desc).first
    end

    # A finished quest reads as full; otherwise ask the goal (the live numbers from the ledger).
    def progress
      @progress ||= if completion
        Goals::Progress.new(current: quest.target, target: quest.target, completed_at: completion.completed_at)
      else
        Goals.check(user, quest)
      end
    end
  end
end
