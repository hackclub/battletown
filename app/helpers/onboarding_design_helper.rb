# Wording and small pieces for the look of the onboarding pages (see app/assets/stylesheets/onboarding_world.css).
module OnboardingDesignHelper
  # Streaks, team and quest bonuses change how many hours a prize really takes, so an hour count is only ever a guide.
  HOURS_NOTE = "Hours are a guide. Daily streaks and team bonuses can get you there faster.".freeze

  # The second line of a prize card: the time a day needed to earn it by the end of the program when that date is set and reachable
  # ("about 30 minutes a day"), else the total hours.
  def onboarding_prize_meta(prize)
    daily = Onboarding::DailyTime.text(Onboarding::DailyTime.minutes_a_day(prize.hours)) if prize.hours
    daily || onboarding_hours_text(prize)
  end

  # "about 4 hours" (nil-safe: a free item has no hours, so its price is shown instead).
  def onboarding_hours_text(prize)
    prize.hours_text ? "about #{prize.hours_text}" : prize.price_text
  end
end
