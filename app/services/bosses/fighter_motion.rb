require "digest"

module Bosses
  # How one circle on the boss stage moves, so that nobody plays in sync with anybody else: each circle gets its own start offset, its own
  # speed, its own bob and its own lunge, all fixed by its opaque key (Fighters::Circle#key: a keyed hash of the person and the boss
  # week, so nothing about who they are goes into it and the same person keeps the same rhythm across polls and page loads in a week).
  #
  # The page's CSP has no style="" attributes, so the numbers cannot ride on the element as custom properties. They are small steps
  # instead, one class per step (stage__fan--da3, see dashboard.css, which turns each step into a custom property), added up in the CSS:
  #
  #   da, db  the start offset (a negative animation-delay, so every circle starts part-way through its cycle): coarse + fine steps
  #   dc, de  the length of one cycle, 2.4 s to 4.2 s: coarse + fine steps
  #   ba      the height of the idle bob
  #   la      how far the lunge reaches (0.75x to 1.35x of the usual)
  #   lb      the sideways drift of the lunge (it lunges toward the boss, a little off the straight line)
  #
  # What the numbers mean is only visual; the tier (shipper: a hard, slow lunge; steady pace: a light, quick jab) is in the CSS, on top.
  # The server renders the classes (_fighter.html.erb) and the live controller builds the same ones from the steps in the live payload
  # (Circle#motion); dashboard.css has a rule per step. The ranges are repeated in both, and fighter_motion_test.rb keeps them in line.
  module FighterMotion
    # step name => how many steps there are
    STEPS = { da: 8, db: 12, dc: 6, de: 10, ba: 4, la: 8, lb: 7 }.freeze
    # The CSS values the steps stand for (the stylesheet repeats them; test/services/bosses/fighter_motion_test.rb keeps both in line).
    DELAY_COARSE = 0.52 # seconds per `da`
    DELAY_FINE = 0.045 # seconds per `db`
    DURATION_BASE = 2.4
    DURATION_COARSE = 0.3 # seconds per `dc`
    DURATION_FINE = 0.03 # seconds per `de`

    module_function

    # The steps for a circle's key: { da: 0..7, db: 0..11, ... }. Each comes from a different byte of the key's SHA-256, so they are
    # independent of one another.
    def for_key(key)
      bytes = Digest::SHA256.digest("bosses/fighter-motion:#{key}").bytes
      STEPS.each_with_index.to_h { |(name, count), index| [ name, bytes[index] % count ] }
    end

    # The animation-delay in seconds (negative: starts part-way through) and the length of the idle cycle in seconds, as the CSS adds them up.
    def delay(steps) = -((steps[:da] * DELAY_COARSE) + (steps[:db] * DELAY_FINE)).round(3)

    def duration(steps) = (DURATION_BASE + (steps[:dc] * DURATION_COARSE) + (steps[:de] * DURATION_FINE)).round(3)

    # The classes on the circle's <li>.
    def classes(steps) = steps.map { |name, step| "stage__fan--#{name}#{step}" }
  end
end
