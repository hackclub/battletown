module LandingHelper
  # The hero painting at four widths (all 1.554:1); image_tag turns the paths into digested URLs.
  HERO_ART_WIDTHS = [ 1280, 1920, 2880, 3840 ].freeze

  def hero_art_srcset
    HERO_ART_WIDTHS.to_h { |w| [ "landing/hero-art-#{w}.webp", "#{w}w" ] }
  end

  # The nine prize cards on the landing page. These are stand-ins (names and hours borrowed from another program,
  # Savepoint), shown only here until Amber finalises the lineup. The real catalog is config/prizes.yml / Prize, which
  # onboarding uses; this list does not touch it.
  LANDING_PRIZES = [
    { name: "8BitDo Micro", hours: "5 hours", image: "landing/prizes/8bitdo-micro.webp" },
    { name: "Redragon K617", hours: "5.5 hours", image: "landing/prizes/redragon-k617.webp" },
    { name: "8BitDo Ultimate 2C", hours: "6 hours", image: "landing/prizes/8bitdo-ultimate-2c.webp" },
    { name: "Attack Shark X3", hours: "8 hours", image: "landing/prizes/attack-shark-x3.webp" },
    { name: "Logitech G203", hours: "8 hours", image: "landing/prizes/logitech-g203.webp" },
    { name: "8BitDo Pro 2", hours: "10 hours", image: "landing/prizes/8bitdo-pro-2.webp" },
    { name: "Keychron K2", hours: "12 hours", image: "landing/prizes/keychron-k2.webp" },
    { name: "8BitDo Ultimate 2", hours: "12 hours", image: "landing/prizes/8bitdo-ultimate-2.webp" },
    { name: "Aula F75", hours: "15 hours", image: "landing/prizes/aula-f75.webp" }
  ].each(&:freeze).freeze

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
