module LandingHelper
  # The hero button only brags about the community once it is a real number worth showing.
  # Below this many signed-up users it says "Join the fight" instead of "Join 3 other fighters".
  FIGHTER_COUNT_THRESHOLD = 10
  FIGHTER_COUNT_CACHE_KEY = "landing/fighter_count".freeze
  BOSS_CACHE_KEY = "landing/boss".freeze

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

  # "Who's locked in": the real number once it is worth showing, otherwise nil (the view shows a waiting message).
  def locked_in_text(count = fighter_count)
    "#{number_with_delimiter(count)} fighters are locked in." if count >= FIGHTER_COUNT_THRESHOLD
  end

  # The boss health bar on the "Fight together" map for a signed-out visitor. Aggregate only: the boss's health left
  # and nothing about any person or about the visitor. Returns plain values (cached for a minute):
  # { live:, percent:, text: }. With no boss standing this week it is a full bar saying the next boss is on its way
  # (live is false).
  def landing_boss
    @landing_boss ||= Rails.cache.fetch(BOSS_CACHE_KEY, expires_in: 1.minute) { build_landing_boss }
  end

  private

  def build_landing_boss
    today = Hours::Days.today("UTC")
    boss = Boss.covering(today).first
    if boss
      facts = Bosses::Presenter::Facts.new(today: today, boss: boss, damage: Bosses::Damage.for(boss), user_seconds: 0,
                                           active_today: 0, upcoming_on: nil, previous_escaped_name: nil)
      presenter = Bosses::Presenter.new(facts: facts)
      case presenter.state
      when :in_progress
        left = presenter.remaining_seconds / 3600
        total = number_with_delimiter(boss.hp_hours)
        text = left.zero? ? "Less than an hour left" : "#{number_with_delimiter(left)} of #{total} hours left"
        return { live: true, percent: presenter.health_percent, text: text }
      when :defeated
        return { live: true, percent: 0, text: "Defeated! The next boss is on its way" }
      end
    end
    { live: false, percent: 100, text: "Full health. The next boss is on its way" }
  end
end
