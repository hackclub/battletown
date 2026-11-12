# The weekly merch track (behind the Flipper flag `merch_track`): hit the daily goal on enough days of a boss week to
# earn that week's item from a fixed track, then claim it once identity is verified (and, when configured, once a ship
# has been approved). Tunables: config/game.yml under `merch_track:` (MerchTrack::Config). No coins are involved.
# Read it all in docs/CONTRACT.md ("Weekly merch track").
module MerchTrack
  # Every failure is one of these, with a message that is fine to show to the person (no ids, no internals).
  class Error < StandardError; end

  class Unavailable < Error
    def initialize(msg = "That isn't available.") = super
  end

  class NoReward < Error
    def initialize(msg = "There is no reward on the track for that week.") = super
  end

  class NotEarned < Error
    def initialize(msg = "You haven't earned that week's reward yet.") = super
  end

  class NotVerified < Error
    def initialize(msg = "Rewards unlock when you verify your identity with Hack Club.") = super
  end

  # Verified, but not eligible for Hack Club YSWS programs (flag `eligibility_gate`): kind, and never says why.
  class NotEligible < Error
    def initialize(msg = "#{Shop::NotEligible::TEXT} #{::Eligibility::Config.current.help_line}") = super
  end

  # Verified, but the sign-in copy of the verification is too old (flag `eligibility_gate`).
  class NeedsRecheck < Error
    def initialize(msg = Shop::NeedsRecheck::TEXT) = super
  end

  class NeedsShip < Error
    def initialize(msg = "Get a project shipped and approved to claim your reward.") = super
  end

  class NotFulfillable < Error
    def initialize(msg = "That claim can't be marked fulfilled.") = super
  end

  class NotCancellable < Error
    def initialize(msg = "That claim can't be cancelled any more.") = super
  end
end
