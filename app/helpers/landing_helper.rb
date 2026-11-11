module LandingHelper
  # The hero button only brags about the community once it is a real number worth showing.
  # Below this many signed-up users it says "Join the fight" instead of "Join 3 other fighters".
  FIGHTER_COUNT_THRESHOLD = 10
  FIGHTER_COUNT_CACHE_KEY = "landing/fighter_count".freeze

  # Real count of signed-up users, cached briefly so the landing page doesn't count the table on every hit.
  def fighter_count
    Rails.cache.fetch(FIGHTER_COUNT_CACHE_KEY, expires_in: 5.minutes) { User.count }
  end

  def join_cta_label(count = fighter_count)
    if count >= FIGHTER_COUNT_THRESHOLD
      "Join #{number_with_delimiter(count)} other fighters"
    else
      "Join the fight"
    end
  end
end
