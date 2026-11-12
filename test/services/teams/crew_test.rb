require "test_helper"
require_relative "../../support/coins_helper"

# Creating, joining, leaving and re-keying a crew, and every limit on them.
class Teams::CrewTest < ActiveSupport::TestCase
  include CoinsHelper

  NOW = Time.utc(2026, 11, 10, 12)

  setup do
    Flipper.enable(:team)
    @ann = build_user
    @ben = build_user
    @cat = build_user
  end

  def config = Teams::Config.current

  test "starting a crew makes the starter its first member with a random short invite link that expires" do
    team = Teams::Crew.create!(user: @ann, name: "  Night   owls ", now: NOW)

    assert_equal "Night owls", team.name
    assert_equal [ @ann.id ], team.memberships.pluck(:user_id)
    assert_equal NOW, team.memberships.sole.joined_at
    assert_match Team::TOKEN_FORMAT, team.invite_token
    assert_equal 16, team.invite_token.length
    assert_equal NOW + 72.hours, team.invite_expires_at
  end

  test "the name is optional, trimmed, and limited" do
    assert_nil Teams::Crew.create!(user: @ann, name: "   ", now: NOW).name
    assert_raises(ActiveRecord::RecordInvalid) { Teams::Crew.create!(user: @ben, name: "x" * 41, now: NOW) }
    assert_raises(ActiveRecord::RecordInvalid) { Teams::Crew.create!(user: @ben, name: "bad\u0007name", now: NOW) }
    assert_equal 1, Team.count
  end

  test "invite tokens are random, long enough to be unguessable, and never repeat" do
    tokens = Array.new(50) { Team.new_token }
    assert_equal 50, tokens.uniq.size
    assert(tokens.all? { |token| token.match?(Team::TOKEN_FORMAT) && token.length == 16 })
    assert_operator Team::TOKEN_BYTES * 8, :>=, 96
  end

  test "one crew at a time: starting or joining a second is refused" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    other = Teams::Crew.create!(user: @ben, now: NOW)

    assert_raises(Teams::Crew::AlreadyInCrew) { Teams::Crew.create!(user: @ann, now: NOW) }
    assert_raises(Teams::Crew::AlreadyInCrew) { Teams::Crew.join!(user: @ann, token: other.invite_token, now: NOW) }
    assert_equal [ 1, 1 ], [ team.memberships.count, other.memberships.count ]
  end

  test "joining with the invite link adds the member with the join time" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    Teams::Crew.join!(user: @ben, token: team.invite_token, now: NOW + 1.hour)

    assert_equal [ @ann.id, @ben.id ], team.memberships.order(:id).pluck(:user_id)
    assert_equal NOW + 1.hour, TeamMembership.find_by!(user_id: @ben.id).joined_at
  end

  test "a crew holds at most the configured number of people" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    extra = Array.new(config.max_size - 1) { build_user }
    extra.each { |user| Teams::Crew.join!(user: user, token: team.invite_token, now: NOW) }
    assert_equal config.max_size, team.memberships.count

    error = assert_raises(Teams::Crew::Full) { Teams::Crew.join!(user: @ben, token: team.invite_token, now: NOW) }
    assert_match(/full/, error.message)
    assert_equal config.max_size, team.memberships.count
  end

  test "an unknown, malformed, expired or replaced link is the same plain error" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    old = team.invite_token

    [ "nope", "a" * 16, "../../etc/passwd", "", nil, "x" * 100 ].each do |token|
      assert_raises(Teams::Crew::InviteInvalid) { Teams::Crew.join!(user: @ben, token: token, now: NOW) }
    end
    assert_raises(Teams::Crew::InviteInvalid) { Teams::Crew.join!(user: @ben, token: old, now: NOW + 73.hours) }

    fresh = Teams::Crew.regenerate_invite!(user: @ann, now: NOW + 1.hour)
    assert_not_equal old, fresh.invite_token
    assert_raises(Teams::Crew::InviteInvalid) { Teams::Crew.join!(user: @ben, token: old, now: NOW + 2.hours) }
    Teams::Crew.join!(user: @ben, token: fresh.invite_token, now: NOW + 2.hours)
    assert_equal 2, team.memberships.count
  end

  test "regenerating also gives the link a fresh expiry, and any member may do it" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    Teams::Crew.join!(user: @ben, token: team.invite_token, now: NOW)
    Teams::Crew.regenerate_invite!(user: @ben, now: NOW + 60.hours)
    assert_equal NOW + 132.hours, team.reload.invite_expires_at
    assert_raises(Teams::Crew::NotInCrew) { Teams::Crew.regenerate_invite!(user: @cat, now: NOW) }
  end

  test "leaving removes the membership, starts the cooldown, and the last one out deletes the crew" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    Teams::Crew.join!(user: @ben, token: team.invite_token, now: NOW)

    Teams::Crew.leave!(user: @ben, now: NOW + 1.day)
    assert_not TeamMembership.exists?(user_id: @ben.id)
    assert_equal NOW + 1.day, TeamCooldown.find_by!(user_id: @ben.id).left_at
    assert Team.exists?(team.id)

    Teams::Crew.leave!(user: @ann, now: NOW + 1.day)
    assert_not Team.exists?(team.id), "an empty crew is deleted"
    assert_raises(Teams::Crew::NotInCrew) { Teams::Crew.leave!(user: @ann, now: NOW) }
  end

  test "after leaving, joining or starting another crew waits for the cooldown, and then works" do
    other = Teams::Crew.create!(user: @cat, now: NOW)
    team = Teams::Crew.create!(user: @ann, now: NOW)
    Teams::Crew.leave!(user: @ann, now: NOW)

    error = assert_raises(Teams::Crew::CoolingDown) { Teams::Crew.join!(user: @ann, token: other.invite_token, now: NOW + 23.hours) }
    assert_equal NOW + 24.hours, error.until_time
    assert_raises(Teams::Crew::CoolingDown) { Teams::Crew.create!(user: @ann, now: NOW + 23.hours) }

    Teams::Crew.join!(user: @ann, token: other.invite_token, now: NOW + 24.hours)
    assert TeamMembership.exists?(user_id: @ann.id, team_id: other.id)
    assert_not TeamCooldown.exists?(user_id: @ann.id), "joining clears the cooldown"
    assert_not Team.exists?(team.id)
  end

  test "leaving never touches coins already paid" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    Coins::Ledger.credit(user: @ann, amount: 7, kind: "team_bonus", idempotency_key: "team_bonus:ship:1")
    Teams::Crew.leave!(user: @ann, now: NOW)
    assert_equal 7, Coins::Balance.total(@ann)
    assert_not Team.exists?(team.id)
  end

  test "renaming works for a member only" do
    Teams::Crew.create!(user: @ann, now: NOW)
    Teams::Crew.rename!(user: @ann, name: "Moon crew")
    assert_equal "Moon crew", TeamMembership.find_by!(user_id: @ann.id).team.name
    assert_raises(Teams::Crew::NotInCrew) { Teams::Crew.rename!(user: @cat, name: "Hijack") }
  end

  test "nothing works while the flag is off, and nothing is written" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    without_feature(:team) do
      assert_raises(Teams::Crew::Disabled) { Teams::Crew.create!(user: @ben) }
      assert_raises(Teams::Crew::Disabled) { Teams::Crew.join!(user: @ben, token: team.invite_token) }
      assert_raises(Teams::Crew::Disabled) { Teams::Crew.leave!(user: @ann) }
      assert_raises(Teams::Crew::Disabled) { Teams::Crew.regenerate_invite!(user: @ann) }
      assert_raises(Teams::Crew::Disabled) { Teams::Crew.rename!(user: @ann, name: "x") }
    end
    assert_equal [ 1, 1, 0 ], [ Team.count, TeamMembership.count, TeamCooldown.count ]
  end

  test "the founder is the longest-standing member" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    Teams::Crew.join!(user: @ben, token: team.invite_token, now: NOW + 1.hour)
    assert_equal @ann, team.founder
    Teams::Crew.leave!(user: @ann, now: NOW + 2.hours)
    assert_equal @ben, team.founder
  end

  test "deleting a user deletes the membership, and the last member deleted takes the crew with them" do
    team = Teams::Crew.create!(user: @ann, now: NOW)
    Teams::Crew.join!(user: @ben, token: team.invite_token, now: NOW)

    Privacy::Deleter.new(Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: @ann.hca_uid)).call(dry_run: false)
    assert_equal [ @ben.id ], TeamMembership.where(team_id: team.id).pluck(:user_id)
    assert Team.exists?(team.id)

    Privacy::Deleter.new(Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: @ben.hca_uid)).call(dry_run: false)
    assert_equal [ 0, 0 ], [ Team.count, TeamMembership.count ]
  end

  # --- the settings ---

  test "the team config is validated when it is read" do
    good = { max_size: 5, bonus_percent: 5.0, leave_cooldown_hours: 24, invite_ttl_hours: 72, pay_pending_days: 3 }
    assert_equal 500, Teams::Config.from_hash(good).bonus_bps
    assert_equal 250, Teams::Config.from_hash(good.merge(bonus_percent: 2.5)).bonus_bps
    assert_raises(ArgumentError) { Teams::Config.from_hash(good.merge(max_size: 1)) }
    assert_raises(ArgumentError) { Teams::Config.from_hash(good.merge(bonus_percent: 2.555)) }
    assert_raises(ArgumentError) { Teams::Config.from_hash(good.merge(bonus_percent: 101)) }
    assert_raises(ArgumentError) { Teams::Config.from_hash(good.merge(invite_ttl_hours: 0)) }
  end

  test "the defaults in config/game.yml" do
    assert_equal [ 5, 500, 24 * 3600, 72 * 3600, 3 ], config.to_h.values
  end
end
