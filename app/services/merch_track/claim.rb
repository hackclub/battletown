module MerchTrack
  # Claims a boss week's item: creates the MerchClaim (status requested). Needs the flag on, an item on the track for
  # that week, `earned?`, a verified identity and (when configured) an approved ship; see MerchTrack::Eligibility.
  #
  # Idempotent per person and week: claiming again returns the existing claim (`created` false) whatever its status,
  # so a double click, a reload or two tabs make exactly one row (the person's row lock serialises them, and the unique
  # index on (user_id, boss_id) backs it up). Nothing about an address is stored: the team messages the person on Slack.
  class Claim
    Result = Data.define(:claim, :created)

    def self.call(...) = new(...).call

    def initialize(user:, boss:, now: Time.current, config: Config.current)
      @user = user
      @boss = boss
      @now = now
      @config = config
    end

    def call
      raise Unavailable unless Features.enabled?(:merch_track)

      item = Track.item_for(@boss, config: @config) or raise NoReward
      settle
      @user.with_lock do
        existing = MerchClaim.find_by(user_id: @user.id, boss_id: @boss.id)
        next Result.new(claim: existing, created: false) if existing

        check_rules!
        claim = MerchClaim.create!(user: @user, boss: @boss, item_key: item.key, item_name: item.name, status: "requested", claimed_at: @now)
        Result.new(claim: claim, created: true)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.new(claim: MerchClaim.find_by!(user_id: @user.id, boss_id: @boss.id), created: false)
    end

    private

    def check_rules!
      case Eligibility.blocker(@user, Progress.for(@user, @boss, now: @now, config: @config), config: @config)
      when :not_earned then raise NotEarned
      when :not_verified then raise NotVerified
      when :needs_ship then raise NeedsShip
      end
    end

    # A day that has just closed may not be settled yet; settling is idempotent and never lets a failure block the claim
    # (an unsettled day simply stays pending). Only the error class is logged.
    def settle
      Game::Settle.call(@user, through: @now)
    rescue StandardError => error
      Rails.logger.error("merch claim settle failed error=#{error.class}")
    end
  end
end
