module Teams
  # Creating, joining, leaving and re-keying a crew. Every change runs in a transaction under the user's row lock (and the
  # crew's, taken after it: lock order is the user, then the crew, like the other services; see docs/CONTRACT.md "Row lock
  # order"), so two tabs or two people joining at once cannot overfill a crew or put one person in two.
  #
  # The rules (config/game.yml `team:`): one crew per person; at most `max_size` people; an invite link works until its
  # expiry and is replaced (the old one stops working) by `regenerate_invite!`; after leaving, `leave_cooldown_hours` pass
  # before joining another crew; a crew with nobody in it is deleted. Leaving never takes back coins already paid.
  # Nothing here works while the `team` flag is off (the controllers 404 first; this is the second lock).
  #
  # Errors carry a friendly sentence for the page (`Error#message`).
  module Crew
    class Error < StandardError; end
    class Disabled < Error; end
    class AlreadyInCrew < Error; end
    class NotInCrew < Error; end
    class InviteInvalid < Error; end
    class Full < Error; end
    class CoolingDown < Error
      attr_reader :until_time

      def initialize(until_time)
        @until_time = until_time
        super("You left a crew recently. You can join another one from #{until_time.utc.strftime('%-d %b %H:%M')} UTC.")
      end
    end

    module_function

    def create!(user:, name: nil, now: Time.current, config: Config.current)
      ensure_enabled!
      user.with_lock do
        raise AlreadyInCrew, "You are already in a crew. Leave it first to start another." if TeamMembership.exists?(user_id: user.id)

        cooldown!(user, now, config)
        team = Team.create!(name: name, invite_token: Team.new_token, invite_expires_at: now + config.invite_ttl_seconds)
        TeamMembership.create!(team: team, user: user, joined_at: now)
        TeamCooldown.where(user_id: user.id).delete_all
        team
      end
    end

    # `token` is what came in the link. An unknown, expired or replaced token is one and the same InviteInvalid, so the
    # answer never says which crews exist.
    def join!(user:, token:, now: Time.current, config: Config.current)
      ensure_enabled!
      user.with_lock do
        team = find_by_token(token)&.then { |found| Team.lock.find_by(id: found.id) }
        raise InviteInvalid, "This invite link does not work any more. Ask your buddy for a new one." unless team&.invite_active?(now)

        raise AlreadyInCrew, "You are already in a crew. Leave it first to join another." if TeamMembership.exists?(user_id: user.id)

        cooldown!(user, now, config)
        raise Full, "This crew is full (#{config.max_size} people)." if team.memberships.count >= config.max_size

        TeamMembership.create!(team: team, user: user, joined_at: now)
        TeamCooldown.where(user_id: user.id).delete_all
        team
      end
    end

    def leave!(user:, now: Time.current)
      ensure_enabled!
      user.with_lock do
        membership = TeamMembership.find_by(user_id: user.id)
        raise NotInCrew, "You are not in a crew." unless membership

        team = Team.lock.find(membership.team_id)
        membership.destroy!
        TeamCooldown.upsert({ user_id: user.id, left_at: now }, unique_by: :user_id)
        team.destroy! unless TeamMembership.exists?(team_id: team.id)
        true
      end
    end

    # A new random token and a fresh expiry; the old link is dead from this moment. Any member can do it.
    def regenerate_invite!(user:, now: Time.current, config: Config.current)
      ensure_enabled!
      user.with_lock do
        membership = TeamMembership.find_by(user_id: user.id) or raise NotInCrew, "You are not in a crew."
        team = Team.lock.find(membership.team_id)
        team.update!(invite_token: Team.new_token, invite_expires_at: now + config.invite_ttl_seconds)
        team
      end
    end

    def rename!(user:, name:)
      ensure_enabled!
      membership = TeamMembership.find_by(user_id: user.id) or raise NotInCrew, "You are not in a crew."
      membership.team.update!(name: name)
    end

    # The crew for an invite token, or nil. A malformed token is nil without touching the database.
    def find_by_token(token)
      return unless token.is_a?(String) && token.match?(Team::TOKEN_FORMAT)

      Team.find_by(invite_token: token)
    end

    def ensure_enabled!
      raise Disabled, "Crews are not available." unless Features.enabled?(:team)
    end

    def cooldown!(user, now, config)
      cooldown = TeamCooldown.find_by(user_id: user.id)
      raise CoolingDown.new(cooldown.ends_at(config)) if cooldown && now < cooldown.ends_at(config)
    end
    private_class_method :cooldown!
  end
end
