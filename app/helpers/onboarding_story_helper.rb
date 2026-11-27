# The words and numbers of the quiz's info screens, built from the person's answers (see Onboarding::Story for the arithmetic). Every string is
# a plain stand-in for Armand to rewrite.
module OnboardingStoryHelper
  # The time frame the person wished for, only when the "When do you want it?" screen was shown for this prize and the pick is one of its dated rows.
  def onboarding_wish
    wish = answers["when"]
    return unless wish && Onboarding::Flow.visible?(Onboarding::Flow.find("when"), answers)

    wish if Onboarding::Story.dated_paces(answers.prize&.hours).any? { |value, _| value == wish }
  end

  def onboarding_pace_minutes = answers.pace_minutes || User::PACE_DEFAULT

  def onboarding_reflection
    Onboarding::Story.reflection(kind: answers.kind, detail: answers["detail"], audience: answers["audience"], size: answers["size"])
  end

  def onboarding_project_phrase
    Onboarding::Story.project_phrase(kind: answers.kind, detail: answers["detail"], audience: answers["audience"])
  end

  def onboarding_prize_date
    prize = answers.prize
    Onboarding::Story.date_at(prize.hours, onboarding_pace_minutes) if prize
  end

  def onboarding_info_title(step)
    prize = answers.prize
    case step
    when "cost" then prize ? "#{prize.name}: #{onboarding_hours_text(prize)} of coding" : "How long it takes"
    when "reflect" then onboarding_reflection || "Your project"
    when "pace_date"
      return "How it adds up" unless prize

      date = onboarding_prize_date
      if Onboarding::DailyTime.reachable?(prize.hours, onboarding_pace_minutes)
        "At #{pace_text(onboarding_pace_minutes)} a day you get your #{prize.name} by #{Onboarding::Story.date_text(date)}"
      else
        "At #{pace_text(onboarding_pace_minutes)} a day your #{prize.name} comes on #{Onboarding::Story.date_text(date)}"
      end
    when "stops_answer" then "Here is what helps"
    when "how" then "How it works"
    when "small" then "First projects are small"
    when "halfway" then "Halfway there"
    when "summary" then "Today, and then"
    end
  end

  # The one true line tying a pace to this week's boss, or nil when no boss stands this week.
  def onboarding_boss_line
    boss = onboarding_boss
    return unless boss.boss? && boss.days_left.positive?

    hours = Onboarding::Story.hours_before(boss.days_left, onboarding_pace_minutes)
    return unless hours

    "This week's boss, #{boss.boss_name}, runs until #{boss.end_day_name}. At that pace you code about #{Onboarding::Story.hours_phrase(hours)} before then."
  end

  # What the daily-time line of the cost screen says: the end-date line when one is set and reachable, else how an hour counts.
  def onboarding_cost_line
    prize = answers.prize
    daily = Onboarding::DailyTime.text(Onboarding::DailyTime.minutes_a_day(prize.hours)) if prize
    ends = Onboarding::DailyTime.ends_on
    return "Every hour you code counts toward it." unless daily

    ends ? "That is #{daily} until #{Onboarding::Story.date_text(ends)}." : "That is #{daily}."
  end
end
