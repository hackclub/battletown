module Onboarding
  # THE list of onboarding steps, in order, in one place. The controller, the progress bar, back and forward, and the tests all read STEPS;
  # adding, removing or reordering a screen is one line here (plus its words in QUESTIONS or INFO for a generic kind).
  #
  # Kinds:  :choice  one tap picks and moves on        :multi  several picks and one Continue        :info  a heading, up to two short lines,
  #         optionally a picture, one Continue, no input      :prize, :pledge, :system  screens with their own page (prize cards, the signed pledge,
  #         identity and Hackatime, the end).
  # `phase` is the old `users.onboarding_step` index this screen belongs to (age 0, prize 1, project 2, schedule 3, signup 4, account 5,
  # celebrate 6): the saved step keeps its meaning, so accounts saved before this list still resume in the right place.
  # `question` counts toward "N questions"; info screens are not counted but the progress bar still moves.
  # `if` hides a screen for answers that make it pointless (a lambda on Onboarding::Answers); hidden screens are skipped both ways.
  module Flow
    Step = Data.define(:key, :kind, :phase, :question, :if)

    def self.step(key, kind, phase, question: false, show: nil) = Step.new(key: key, kind: kind, phase: phase, question: question, if: show)

    # Not answered yet counts as shown (the progress bar then keeps its length); only a kind of "Not sure yet" hides the project follow-ups.
    specific = ->(a) { a.kind != "undecided" }

    STEPS = [
      step("age", :choice, 0, question: true),
      step("prize", :prize, 1, question: true),
      step("use", :choice, 2, question: true),
      step("cost", :info, 2),
      step("how", :info, 2),
      step("when", :choice, 2, question: true, show: ->(a) { Story.when_worth_asking?(a.prize&.hours) }),
      step("made", :choice, 2, question: true),
      step("project", :choice, 2, question: true),
      step("detail", :choice, 2, question: true, show: specific),
      step("audience", :choice, 2, question: true, show: specific),
      step("started", :choice, 2, question: true, show: specific),
      step("size", :choice, 2, question: true, show: specific),
      step("crew", :choice, 2, question: true, show: ->(a) { a.kind != "undecided" && Features.enabled?(:team) }),
      step("reflect", :info, 2, show: specific),
      step("idea", :choice, 2, question: true, show: ->(a) { a.kind == "undecided" }), # only the "Not sure yet" path: elsewhere "started" covers it
      step("editor", :choice, 2, question: true),
      step("coding_when", :choice, 2, question: true),
      step("small", :info, 2),
      step("schedule", :choice, 3, question: true),
      step("pace_date", :info, 3),
      step("stops", :multi, 3, question: true),
      step("stops_answer", :info, 3, show: ->(a) { a["stops"].nil? || Story.obstacle_lines(a.multi("stops")).any? }),
      step("summary", :info, 3),
      step("signup", :pledge, 4),
      step("account", :system, 5),
      step("celebrate", :system, 6)
    ].freeze

    KEYS = STEPS.map(&:key).freeze
    # Steps that carry a prize picture of their own: the docked corner picture is hidden on them (reflect draws the project kind instead, so the dock stays).
    PRIZE_PICTURE_STEPS = %w[cost pace_date summary].freeze

    module_function

    def keys = KEYS
    def find(key) = STEPS.find { |step| step.key == key }
    def index(key) = KEYS.index(key)
    def phase(key) = find(key)&.phase.to_i

    def visible?(step, answers, signed_in: false)
      return false if signed_in && %w[age signup].include?(step.key)

      step.if.nil? || step.if.call(answers)
    end

    # The screens this person will see, in order.
    def visible(answers, signed_in: false) = STEPS.select { |step| visible?(step, answers, signed_in: signed_in) }

    # The first visible step at or after `index`.
    def from(index, answers, signed_in: false)
      STEPS.drop(index.to_i).find { |step| visible?(step, answers, signed_in: signed_in) }&.key || KEYS.last
    end

    def next_key(key, answers, signed_in: false)
      keys = visible(answers, signed_in: signed_in).map(&:key)
      return keys[keys.index(key) + 1] || KEYS.last if keys.include?(key)

      from(index(key) + 1, answers, signed_in: signed_in) # the screen they are on has just been hidden: the next one in the fixed order
    end

    def previous_key(key, answers, signed_in: false)
      keys = visible(answers, signed_in: signed_in).map(&:key)
      return keys[keys.index(key) - 1] if keys.include?(key) && keys.index(key).positive?
      return if keys.include?(key)

      STEPS.take(index(key)).reverse.find { |step| visible?(step, answers, signed_in: signed_in) }&.key
    end

    # [position (1-based), total] among the screens this person will see.
    def progress(key, answers, signed_in: false)
      list = visible(answers, signed_in: signed_in).map(&:key)
      [ (list.index(key) || index_among(list, key)) + 1, list.size ]
    end

    def index_among(list, key) = list.count { |k| index(k) < index(key) }
  end
end
