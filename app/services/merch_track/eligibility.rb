module MerchTrack
  # The claim rules, in one place so the page and the claim agree. In order: the week's goal days are earned, then
  # identity is verified with Hack Club (the same lock the shop uses; coding is never blocked by it), then, when
  # `claim_requires_ship` is on, at least one ship of the person's has been approved (ever: a ship approved in a later
  # week still unlocks an earlier week's reward, because the point is that the reward follows real shipped work).
  module Eligibility
    module_function

    # nil when the person can claim, otherwise :not_earned, :not_verified or :needs_ship.
    def blocker(user, progress, config: Config.current)
      return :not_earned unless progress.earned?
      return :not_verified unless user.verification_verified?
      return :needs_ship if config.claim_requires_ship && !shipped?(user)

      nil
    end

    def shipped?(user) = Ship.exists?(user_id: user.id, status: "approved")
  end
end
