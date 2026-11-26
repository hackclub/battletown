require "zlib"

# Player profiles (projects/battletown/specs/contract.md "Player profiles"): every player has one, and every signed-in, onboarded
# player can open it. There is no opt-in and no opt-out (owner decision, projects/battletown/DECISIONS.md).
#
# What other players may see is a NAME, a picture, damage and project facts (Profiles::Presenter), never the real name, email, Slack id
# or Hack Club Auth id. The page's address is the opaque random `public_slug`, made when the account is made and never changed; the
# numeric id is never in a profile URL.
#
# The name shown (PublicProfile.name_for) is, in this order:
#   1. `profile_name`, the display name the player typed in Settings (optional, up to NAME_MAX characters),
#   2. their Slack display name, as SlackProfiles stored it, when "Use my Slack name and picture" is on (it is, until they turn it off),
#   3. a generated handle taken from the address ("Brave Otter 42"), so it is stable and never a real name.
module PublicProfile
  extend ActiveSupport::Concern

  NAME_MAX = 30
  # Letters, numbers, spaces and . _ - ' only, starting with a letter or number (so no "@", "/", ":" or emoji tricks).
  NAME_FORMAT = /\A[\p{L}\p{N}][\p{L}\p{N} ._'\-]*\z/
  # Something that reads as a web address ("evil.com") is not a name.
  NAME_LOOKS_LIKE_ADDRESS = /[\p{L}\p{N}]\.[\p{L}]{2,}/
  # Names that read as the team or the app: nobody gets a clickable circle that looks official (checked when a name is typed, and on
  # a Slack name before it is shown).
  NAME_RESERVED_RUN = /hackclub|battletown/
  NAME_RESERVED_WORD = /\b(staff|admin|administrator|moderator)\b/i
  SLUG_LENGTH = 11
  SLUG_FORMAT = /\A[a-z0-9]{10,12}\z/
  DEFAULT_NAME = "Player".freeze
  HANDLE_ADJECTIVES = %w[Brave Calm Clever Cosmic Curious Daring Eager Fuzzy Gentle Happy Jolly Lucky Mighty Nimble Quick Sunny].freeze
  HANDLE_ANIMALS = %w[Otter Fox Heron Lynx Panda Gecko Newt Moth Wren Hare Badger Falcon Koala Lemur Owl Puffin].freeze

  included do
    normalizes :profile_name, with: ->(name) { name.to_s.unicode_normalize(:nfc).squish.presence }

    before_validation :assign_public_slug, on: :create

    validates :profile_name, length: { maximum: NAME_MAX }
    validates :profile_name, format: { with: NAME_FORMAT, message: "can only use letters, numbers, spaces and . _ - '" }, allow_nil: true
    validate :profile_name_is_not_an_address
    validate :profile_name_is_not_reserved, if: :profile_name_changed?
    validates :public_slug, format: { with: SLUG_FORMAT }, uniqueness: true
  end

  class_methods do
    # The player whose page is at this address, or nil for an address nobody has and one that cannot be an address.
    def by_slug(slug) = (find_by(public_slug: slug.to_s) if slug.to_s.match?(SLUG_FORMAT))

    def generate_public_slug
      loop do
        slug = SecureRandom.random_number(36**SLUG_LENGTH).to_s(36).rjust(SLUG_LENGTH, "0")
        return slug unless exists?(public_slug: slug)
      end
    end
  end

  # The name other players see: the chosen name, else the Slack name (pass nil unless "use my Slack name" is on), else the handle.
  # A Slack name that could pass for the team ("Hack Club Staff") is not shown.
  def self.name_for(profile_name:, slack_name:, slug:)
    profile_name.presence || usable_slack_name(slack_name) || handle_for(slug)
  end

  # "Brave Otter 42": the same for the same address, made of two word lists and two digits. Never a real name.
  def self.handle_for(slug)
    return DEFAULT_NAME if slug.blank?

    bits = Zlib.crc32(slug.to_s)
    adjectives = HANDLE_ADJECTIVES.size
    animals = HANDLE_ANIMALS.size
    "#{HANDLE_ADJECTIVES[bits % adjectives]} #{HANDLE_ANIMALS[(bits / adjectives) % animals]} #{(bits / (adjectives * animals)) % 90 + 10}"
  end

  # A Slack name passes the same rules as a typed one (NAME_FORMAT, not an address, not the team's words, at most NAME_MAX); otherwise
  # nil, and the handle is shown.
  def self.usable_slack_name(name)
    name = name.to_s.squish.presence
    return if name.nil? || name.length > NAME_MAX
    return unless name.match?(NAME_FORMAT) && !name.match?(NAME_LOOKS_LIKE_ADDRESS)

    name unless reserved_name?(name)
  end

  def self.reserved_name?(name)
    name.to_s.downcase.gsub(/[^\p{L}\p{N}]/, "").match?(NAME_RESERVED_RUN) || name.to_s.match?(NAME_RESERVED_WORD)
  end

  # The name this player is shown as. `slack_profile` is their SlackProfile row when the caller already has it (without the picture
  # bytes); it is looked up otherwise.
  def public_name(slack_profile = SlackProfile.for(self))
    PublicProfile.name_for(profile_name: profile_name, slack_name: slack_name_for(slack_profile), slug: public_slug)
  end

  # What they are shown as when they have no display name of their own: the Slack name when "use my Slack name" is on and one is
  # stored, else the generated handle. (Settings shows it as the hint under the Display name field.)
  def fallback_name(slack_profile = SlackProfile.for(self))
    PublicProfile.name_for(profile_name: nil, slack_name: slack_name_for(slack_profile), slug: public_slug)
  end

  private

  def slack_name_for(slack_profile) = (slack_profile&.display_name if SlackProfiles.use_name?(slack_profile))

  def assign_public_slug
    self.public_slug ||= self.class.generate_public_slug
  end

  def profile_name_is_not_reserved
    errors.add(:profile_name, "can't use that word (it could look like it comes from the Hack Club team)") if PublicProfile.reserved_name?(profile_name)
  end

  def profile_name_is_not_an_address
    errors.add(:profile_name, "can't look like a web address") if profile_name.to_s.match?(NAME_LOOKS_LIKE_ADDRESS)
  end
end
