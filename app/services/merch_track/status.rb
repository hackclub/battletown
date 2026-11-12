module MerchTrack
  # Everything a card or a track row says about one boss week for one person, as plain values and ready-made
  # sentences (the views have no rules of their own). `state` is one of:
  #   :claimed :fulfilled :cancelled        a claim exists (its own status)
  #   :claimable                            earned, and nothing blocks the claim
  #   :needs_verification :needs_recheck :not_eligible :needs_ship
  #                                         earned, but the claim is locked (never blocks coding; the three identity states are
  #                                         User#spend_state: the last two exist only with the `eligibility_gate` flag on)
  #   :in_progress                          not earned yet, and the week can still get there
  #   :fresh_start                          not earned, and the week can no longer get there ("never 'you missed it'")
  # Copy never shames a short week.
  class Status
    attr_reader :progress, :claim, :user

    def self.for(user, boss, now: Time.current, config: Config.current, claim: :load)
      new(user, boss, now: now, config: config, claim: claim)
    end

    def initialize(user, boss, now:, config:, claim: :load)
      @user = user
      @config = config
      @progress = Progress.for(user, boss, now: now, config: config)
      @claim = claim == :load ? MerchClaim.find_by(user_id: user.id, boss_id: boss.id) : claim
    end

    def boss = progress.boss

    def item = progress.item

    def count_text = "#{progress.met} of #{progress.required} days"

    # "Goal days are days you code 60 minutes or more."
    def goal_rule_text = "A goal day is a day you code #{Game::Config.current.goal_seconds / 60} minutes or more."

    def state
      @state ||= if claim then claim_state
      elsif progress.earned? then earned_state
      elsif progress.reachable? then :in_progress
      else :fresh_start
      end
    end

    def can_claim? = state == :claimable

    # Show the verify link (the shop's own Hack Club link) next to the message.
    def needs_verification? = state == :needs_verification

    def message
      case state
      when :claimed then "Claimed. The team will message you on Slack to arrange delivery."
      when :fulfilled then "The team has arranged delivery. Enjoy!"
      when :cancelled then "This claim was cancelled. Message the team on Slack if that looks wrong."
      when :claimable then "You earned it! Claim it and the team will message you on Slack to arrange delivery."
      when :needs_verification then "You earned it! Verify your identity with Hack Club to claim it. Coding is never blocked."
      when :needs_recheck then "You earned it! #{Shop::NeedsRecheck::TEXT} Coding is never blocked."
      when :not_eligible then "You earned it! #{Shop::NotEligible::TEXT} #{::Eligibility::Config.current.help_line}"
      when :needs_ship then "You earned it! Ship a project and get it approved, then you can claim it."
      when :in_progress then in_progress_text
      else "Next week is a fresh start."
      end
    end

    private

    def claim_state
      claim.status.to_sym == :requested ? :claimed : claim.status.to_sym
    end

    def earned_state
      case Eligibility.blocker(user, progress, config: @config)
      when :not_verified then :needs_verification
      when :needs_recheck then :needs_recheck
      when :not_eligible then :not_eligible
      when :needs_ship then :needs_ship
      else :claimable
      end
    end

    def in_progress_text
      to_go = progress.to_go
      left = progress.open_days
      "#{to_go} more goal #{to_go == 1 ? 'day' : 'days'} to go, with #{left} #{left == 1 ? 'day' : 'days'} left this week."
    end
  end
end
