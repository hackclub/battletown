module Onboarding
  # The words of every generic screen (the :choice and :multi kinds of Onboarding::Flow). Every string here is a plain stand-in for Armand
  # to rewrite. An option is { value:, label:, detail: (second line, on the right of the row), apart: (the opt-out row) }.
  module Questions
    Q = Data.define(:title, :lead, :layout, :options)

    module_function

    def pick(*pairs) = pairs.map { |value, label| { value: value, label: label } }

    KIND_FOLLOW_UP = {
      "game" => [ "What kind of game?", [ %w[platformer Platformer], %w[puzzle Puzzle], %w[story Story], %w[multiplayer Multiplayer], [ "other", "Something else" ] ] ],
      "website" => [ "What kind of website?", [ %w[portfolio Portfolio], [ "club", "A club or cause" ], [ "tool", "A tool people use" ], [ "blog", "A blog" ], [ "other", "Something else" ] ] ],
      "app" => [ "What kind of app?", [ %w[phone Phone], %w[desktop Desktop], %w[web Web], [ "other", "Something else" ] ] ],
      "tool" => [ "What kind of tool or bot?", [ [ "bot", "Discord or Slack bot" ], [ "cli", "Command line" ], [ "extension", "Browser extension" ], [ "other", "Something else" ] ] ]
    }.freeze

    # "controller", "keyboard" or nil, from the prize's name (the shop keys no longer say what the item is).
    def prize_kind(prize)
      name = prize&.name.to_s
      return "controller" if name.match?(/8BitDo|controller|gamepad/i)

      "keyboard" if name.match?(/keychron|redragon|aula|keyboard/i)
    end

    def use_options(prize)
      case prize_kind(prize)
      when "controller" then pick([ "friends", "Play games with friends" ], [ "alone", "Play my favorites on my own" ], [ "test", "Test the games I make" ], [ "other", "Something else" ])
      when "keyboard" then pick([ "code", "Code on it every day" ], [ "fast", "Type faster" ], [ "desk", "Make my desk setup better" ], [ "other", "Something else" ])
      else pick([ "daily", "Use it every day" ], [ "show", "Show it to my friends" ], [ "later", "Keep it for later" ], [ "other", "Something else" ])
      end
    end

    # The screen for a generic :choice or :multi key, given Onboarding::Answers.
    def for(key, answers)
      case key
      when "use" then Q.new(answers.prize ? "What would you do with your #{answers.prize.name}?" : "What would you do with it?", nil, :rows, use_options(answers.prize))
      when "when"
        frames = Story.frame_options(answers.prize&.hours)
        Q.new("When do you want it?", nil, :rows, frames.map { |value, label, detail| { value: value, label: label, detail: detail } })
      when "made" then Q.new("Have you made something before?", nil, :rows, pick([ "never", "Never" ], [ "little", "A little" ], [ "few", "A few projects" ], [ "lots", "Lots" ]))
      when "detail"
        title, options = KIND_FOLLOW_UP[answers.kind] || KIND_FOLLOW_UP["tool"]
        Q.new(title, nil, :rows, pick(*options))
      when "audience" then Q.new("Who is it for?", nil, :rows, pick([ "me", "Just me" ], [ "friends", "My friends" ], [ "school", "People at my school" ], [ "anyone", "Anyone online" ]))
      when "started" then Q.new("Have you started it?", nil, :rows, pick([ "not_yet", "Not yet" ], [ "plan", "I have a plan" ], [ "code", "I have some code" ], [ "nearly", "It is nearly done" ]))
      when "size"
        Q.new("How big is it?", nil, :rows, pick([ "weekend", "A weekend thing" ], [ "weeks", "A few weeks" ], [ "biggest", "My biggest project yet" ]))
      when "crew" then Q.new("Are you building alone?", nil, :rows, pick([ "alone", "Alone" ], [ "friends", "With friends" ]))
      when "idea" then Q.new("Do you have an idea yet?", nil, :rows, pick([ "yes", "Yes" ], [ "kind", "Kind of" ], [ "no", "Not yet" ]))
      when "editor"
        Q.new("What do you code in?", nil, :rows, OnboardingsHelper::HACKATIME_EDITORS.map { |e| { value: e[:key], label: e[:name] } } + [ { value: "other", label: "Something else", apart: true } ])
      when "coding_when" then Q.new("When do you usually code?", nil, :rows, pick([ "before_school", "Before school" ], [ "after_school", "After school" ], [ "late", "Late at night" ], [ "weekends", "Weekends" ]))
      when "stops"
        Q.new("What usually stops you finishing?", "Pick all that apply.", :rows, pick([ "time", "I ran out of time" ], [ "stuck", "I got stuck" ], [ "lost", "I lost motivation" ], [ "idea", "I had no idea what to build" ], [ "none", "Nothing, I finish things" ]))
      end
    end
  end
end
