module Onboarding
  # The sentences and sums the quiz builds from a person's answers. Everything here is arithmetic on real numbers (the shop price, the
  # coin rate, the end date, this week's boss, the ship minimum and reminder hours from config/game.yml) or a plain join of what they picked.
  module Story
    NBSP = " ".freeze

    DETAILS = {
      "game" => { "platformer" => "A platformer game", "puzzle" => "A puzzle game", "story" => "A story game", "multiplayer" => "A multiplayer game", "other" => "A game" },
      "website" => { "portfolio" => "A portfolio site", "club" => "A club or cause site", "tool" => "A web tool", "blog" => "A blog", "other" => "A website" },
      "app" => { "phone" => "A phone app", "desktop" => "A desktop app", "web" => "A web app", "other" => "An app" },
      "tool" => { "bot" => "A Discord or Slack bot", "cli" => "A command-line tool", "extension" => "A browser extension", "other" => "A tool or bot" }
    }.freeze
    AUDIENCES = { "me" => "for just you", "friends" => "for your friends", "school" => "for people at your school", "anyone" => "for anyone online" }.freeze
    SIZES = { "weekend" => "a weekend of work", "weeks" => "a few weeks of work", "biggest" => "your biggest project yet" }.freeze

    # Time frames for "When do you want it?": [value, label, days (nil: the end date, or no deadline)].
    FRAMES = [ [ "two_weeks", "In 2 weeks", 14 ], [ "month", "In a month", 30 ], [ "program", "By the end of the program", :program ], [ "no_rush", "No rush", nil ] ].freeze

    # Hack Club's own numbers for the "first projects are small" screen: each person's first approved project, reviewed hours, n = 17,053
    # (research 2026-11-27, hack-club-stats.md row 14: 54.2% took 5 hours or less, 73.9% took 10 hours or less). The bars are separate groups that add
    # to 100%, both derived by subtraction from those same 17,053 projects: 73.9 - 54.2 = 19.7 took more than 5 and up to 10 hours, 100 - 73.9 = 26.1 took more.
    FIRST_PROJECTS = [
      { label: "5 hours or less", percent: 54.2 },
      { label: "5 to 10 hours", percent: 19.7 },
      { label: "More than 10 hours", percent: 26.1 }
    ].freeze
    FIRST_PROJECT_MEDIAN = 4.8

    module_function

    def today = Time.zone.today

    # "A puzzle game for your friends, a few weeks of work." Parts nobody answered are left out; the last two words never part (no orphan).
    def reflection(kind:, detail:, audience:, size:)
      head = DETAILS.dig(kind, detail) || DETAILS.dig(kind, "other")
      return unless head

      text = [ [ head, AUDIENCES[audience] ].compact.join(" "), SIZES[size] ].compact.join(", ")
      glue_end("#{text}.")
    end

    # The same text with only the project, for the summary's "after" side: "A puzzle game for your friends".
    def project_phrase(kind:, detail:, audience:)
      head = DETAILS.dig(kind, detail) || DETAILS.dig(kind, "other")
      [ head, AUDIENCES[audience] ].compact.join(" ") if head
    end

    def glue_end(text)
      words = text.split(" ")
      return text if words.size < 3

      (words[0..-3] + [ words.last(2).join(NBSP) ]).join(" ")
    end

    # Days to earn `hours` at `minutes` a day, every day, counting today as day one.
    def days_to_earn(hours, minutes)
      (hours.to_r * 60 / minutes).ceil if minutes.to_i.positive? && hours.to_f.positive?
    end

    # The day the prize is earned at that pace (day one is today).
    def date_at(hours, minutes, from: today)
      days = days_to_earn(hours, minutes)
      from + (days - 1) if days
    end

    def date_text(date) = date.strftime("%B %-d")

    # [[value, label, detail]] for "When do you want it?". Each detail is the time a day that frame needs for THIS prize, computed. A frame
    # that needs more than the biggest pace choice a day (DailyTime::PACES), or lies past the end date when one is set, is not offered.
    def frame_options(hours, ends_on: DailyTime.ends_on, today: self.today)
      left = DailyTime.days_left(today: today, ends_on: ends_on)
      return [] if ends_on && !left.to_i.positive?

      FRAMES.filter_map do |value, label, days|
        if days == :program
          next unless left
          days = left
        elsif days
          next if left && days > left
        else
          next [ value, label, nil ]
        end
        minutes = DailyTime.minutes_over(hours, days)
        next unless minutes

        [ value, label, DailyTime.text(minutes) ]
      end
    end

    # The minutes a day each dated frame needs for this prize (every offered frame but "No rush").
    def dated_paces(hours, ends_on: DailyTime.ends_on, today: self.today)
      frame_options(hours, ends_on: ends_on, today: today).filter_map { |value, _, detail| detail && [ value, detail ] }
    end

    # Is "When do you want it?" worth asking for this prize? Only when its dated frames lead to at least two different paces: a question whose
    # answers all end the same way changes nothing, so it is dropped.
    def when_worth_asking?(hours, ends_on: DailyTime.ends_on, today: self.today)
      dated_paces(hours, ends_on: ends_on, today: today).map(&:last).uniq.size >= 2
    end

    # "You wanted it in a month." for the pace step, from the time frame they picked; nil for "No rush" or nothing picked.
    def wish_line(frame)
      _, label, days = FRAMES.find { |value, _, _| value == frame }
      "You wanted it #{label.sub(/\A./, &:downcase)}." if label && days
    end

    # The pace (from the pace step's choices) that meets a time frame: the smallest that earns the prize in time, else the biggest.
    def pace_for(frame, hours, paces, ends_on: DailyTime.ends_on, today: self.today)
      days = FRAMES.find { |value, _, _| value == frame }&.last
      days = DailyTime.days_left(today: today, ends_on: ends_on) if days == :program
      return unless days.is_a?(Integer) && days.positive? && hours.to_f.positive?

      needed = (hours.to_r * 60 / days).ceil
      paces.find { |pace| pace >= needed } || paces.max
    end

    # Hours of coding that fit in the days from today to the boss week's end at a daily pace (today counts).
    def hours_before(days_left, minutes)
      return unless days_left.to_i.positive? && minutes.to_i.positive?

      hours = (days_left * minutes) / 60.0
      hours == hours.to_i ? hours.to_i : hours.round(1)
    end

    def hours_phrase(hours) = "#{hours} #{hours == 1 ? 'hour' : 'hours'}"

    # What helps with each thing that stops people finishing: [acknowledgement, a real feature]. Only features that exist get a line:
    # the ship minimum and reminder hours come from config, the crew bonus only while the crew flag is on, the boss week from Boss.
    def obstacle_lines(picked, team: Features.enabled?(:team)) = obstacle_entries(picked, team: team).map { |_, acknowledgement, feature| [ acknowledgement, feature ] }

    # The same lines with the thing that stops them: [[key, acknowledgement, feature]], in the order picked (the key picks the screen's icon).
    def obstacle_entries(picked, team: Features.enabled?(:team))
      cfg = Ships::Config.current
      min = (cfg.min_seconds / 3600.0)
      min = min == min.to_i ? min.to_i : min
      first, second = cfg.reminder_seconds.map { |seconds| (seconds / 3600.0).then { |h| h == h.to_i ? h.to_i : h } }
      lines = {
        "time" => [ "Short on time?", "A project can ship after just #{hours_phrase(min)} of coding." ],
        "lost" => [ "Losing motivation?", "Each boss week runs Friday to Thursday, and Slack reminds you to ship at #{first} and #{second} hours." ]
      }
      lines["stuck"] = [ "Getting stuck?", "Code on the same days as your crew and you earn a bonus." ] if team
      picked.filter_map { |value| [ value, *lines[value] ] if lines[value] }
    end
  end
end
