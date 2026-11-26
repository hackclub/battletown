require "json"
require "fileutils"
require "securerandom"

module DevSimulator
  # Makes the local manifest of real Slack members that DevSimulator::Looks dresses the simulated players in (DevSimulator::SlackManifest):
  # a random sample of a channel's members, each one's display name and profile picture. It is a development helper for
  # `bin/rails dev:slack_players[COUNT]` and writes only into the git-ignored directory SlackManifest.directory (tmp/dev_slack).
  #
  # The member ids come from `tmp/dev_slack/members.json` when it is there (a JSON array of Slack user ids, or {"members": [...],
  # "exclude": [...]}: written by hand or by whatever tool could list the channel), otherwise from the Slack API
  # (DevSimulator::SlackMembers, which needs the `channels:read` scope). Each member is then read through the app's own guarded pipeline:
  # SlackProfiles::Client (users.info, so deleted accounts and bots are dropped), SlackProfiles::Download (https on slack-edge.com / slack.com
  # only, 1 MB cap) and SlackProfiles::Avatar (a 128 px WebP, no metadata), the name through SlackProfiles::Sanitizer. Someone without a
  # display name or a picture of their own is skipped. The display name is used as is when it is one word; with a space in it only the first
  # word is kept (a real full name is never put in the demo). The owner and anyone listed under "exclude" or in DEV_SLACK_EXCLUDE
  # (comma separated Slack ids) are left out, and so is a first name in EXCLUDED_FIRST_NAMES.
  #
  # The result is ONE manifest of {name, picture file} (no Slack ids) and the WebP files. The ids, names and pictures stay on this
  # machine: never in git, a seed, a fixture, a test or a log (the report below holds counts only).
  class SlackSample
    class Failed < StandardError; end

    Report = Data.define(:members, :tried, :written)

    DEFAULT_COUNT = 24
    MAX_COUNT = 200
    EXCLUDED_FIRST_NAMES = %w[amber armand].freeze
    MEMBERS_FILE = "members.json".freeze
    SETUP_CODES = %w[no_token invalid_auth not_authed token_revoked missing_scope account_inactive].freeze
    DOWNLOAD_PAUSE = 0.7 # seconds between members: about 85 users.info calls a minute at most (Tier 4 allows 100)

    def self.call(**args) = new(**args).call

    def initialize(count: DEFAULT_COUNT, channel: nil, directory: SlackManifest.directory, client: SlackProfiles::Client.new, random: Random.new,
                   members: nil, pause: DOWNLOAD_PAUSE)
      @count = DevSimulator.whole_number(count, 1..MAX_COUNT, "count")
      @channel = channel
      @directory = Pathname.new(directory)
      @client = client
      @random = random
      @members = members
      @pause = pause
    end

    def call
      DevSimulator.check_local_database!
      raise Failed, "Refusing to run in production." if Rails.env.production?

      ids = member_ids
      raise Failed, "No members to sample: put Slack user ids in #{@directory.join(MEMBERS_FILE)} or give a channel the bot can read." if ids.empty?

      people, tried = sample(ids)
      raise Failed, "None of the #{tried} members tried had a display name and a profile picture of their own." if people.empty?

      write(people)
      Report.new(members: ids.size, tried: tried, written: people.size)
    end

    private

    # The ids to draw from, the owner's and the excluded ones already removed.
    def member_ids
      from_file = read_members_file
      ids = @members || from_file[:members].presence || channel_members
      excluded = from_file[:exclude] + ENV["DEV_SLACK_EXCLUDE"].to_s.split(",").map(&:strip)
      ids.grep(String).select { |id| id.match?(SlackProfiles::Client::SLACK_ID_FORMAT) }.uniq - excluded
    end

    def read_members_file
      data = JSON.parse(@directory.join(MEMBERS_FILE).read)
      data = { "members" => data } if data.is_a?(Array)
      { members: Array(data["members"]), exclude: Array(data["exclude"]).grep(String) }
    rescue JSON::ParserError, SystemCallError
      { members: [], exclude: [] }
    end

    def channel_members
      channel = @channel.presence || ENV["DEV_SLACK_CHANNEL"].presence || "ambers-mountain"
      SlackMembers.call(channel)
    rescue SlackMembers::Failed => error
      hint = error.message == "missing_scope" ? " (the Slack app needs the channels:read bot scope, or write the member ids into #{@directory.join(MEMBERS_FILE)})" : ""
      raise Failed, "Could not list the channel members: #{error.message}#{hint}"
    end

    # Reads members in random order until COUNT usable people are found (or every member has been tried).
    def sample(ids)
      people = []
      tried = 0
      ids.shuffle(random: @random).each do |id|
        break if people.size >= @count

        tried += 1
        person = person_for(id)
        people << person if person && people.none? { |other| other[:profile_name].casecmp?(person[:profile_name]) }
        sleep(@pause) if @pause.positive?
      end
      [ people, tried ]
    end

    def person_for(id)
      result = @client.user_info(id)
      unless result.ok?
        raise Failed, "Slack refused the profile lookup (#{result.error_code}); check SLACK_BOT_TOKEN and the users:read scope." if SETUP_CODES.include?(result.error_code)
        raise Failed, "Slack asked us to slow down (#{result.error_code}); run it again in a minute." if result.error_code == "ratelimited"

        return
      end
      return unless result.image_url

      name = usable_name(result.name)
      return unless name

      picture = SlackProfiles::Avatar.call(SlackProfiles::Download.call(result.image_url))
      { name: name, profile_name: SlackProfiles::Sanitizer.profile_name(name), picture: picture }
    rescue SlackProfiles::Download::Refused, SlackProfiles::Avatar::Rejected
      nil
    end

    def usable_name(raw)
      name = SlackProfiles::Sanitizer.display_name(raw)
      name = name.split.first if name&.include?(" ")
      return if name.nil? || EXCLUDED_FIRST_NAMES.include?(name.downcase)

      name if SlackProfiles::Sanitizer.profile_name(name)
    end

    # The new files replace the old ones in one go (old player-NN files and the manifest are removed first, the manifest is written last).
    def write(people)
      FileUtils.mkdir_p(@directory, mode: 0o700)
      Dir.glob(@directory.join("player-*.webp")).each { |path| File.delete(path) }
      rows = people.each_with_index.map do |person, index|
        file = format("player-%02d.webp", index + 1)
        File.binwrite(@directory.join(file), person[:picture].content)
        { name: person[:name], picture: file }
      end
      temp = @directory.join("#{SlackManifest::FILE}.#{SecureRandom.hex(4)}.tmp")
      File.write(temp, JSON.pretty_generate(players: rows))
      File.rename(temp, @directory.join(SlackManifest::FILE))
    end
  end
end
