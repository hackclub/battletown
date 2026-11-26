require "json"

module DevSimulator
  # The local, uncommitted list of real Slack members (a display name and a picture file each) that simulated players are dressed in,
  # so a development demo shows real-looking names and faces. It is dev-only demo data owned by the machine it sits on:
  #
  #   tmp/dev_slack/manifest.json   {"players": [{"name": "...", "picture": "player-01.webp"}, ...]}
  #   tmp/dev_slack/player-01.webp  the picture, already through SlackProfiles::Avatar (128 px WebP, no metadata)
  #
  # The directory is inside tmp/, which git ignores, and nothing in it is ever read in production. It is made by
  # `bin/rails dev:slack_players` (DevSimulator::SlackSample). The manifest holds NO Slack ids. `DEV_SLACK_DIR` points the loader somewhere
  # else (the tests use a temp directory, so they never touch the real data).
  #
  # A missing, unreadable or malformed manifest is not an error: `entries` is just empty and the simulator keeps its generated
  # names and pictures (DevSimulator::Looks). A bad entry (no usable name, a picture that is not there) is skipped, and a name is
  # never listed twice.
  module SlackManifest
    Entry = Data.define(:name, :profile_name, :picture_path)

    FILE = "manifest.json".freeze
    PICTURE_FILE = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,60}\.(?:webp|png|jpe?g|gif)\z/
    MAX_MANIFEST_BYTES = 200_000
    MAX_ENTRIES = DevSimulator::MAX_PLAYERS

    module_function

    def directory = Pathname.new(ENV["DEV_SLACK_DIR"].presence || Rails.root.join("tmp", "dev_slack").to_s)

    def manifest_path = directory.join(FILE)

    # The usable entries, in file order.
    def entries
      return [] if Rails.env.production?

      read.filter_map { |row| entry_from(row) }.uniq { |entry| entry.profile_name.downcase }.first(MAX_ENTRIES)
    end

    def profile_names = entries.map(&:profile_name)

    def read
      path = manifest_path
      return [] unless path.file? && path.size <= MAX_MANIFEST_BYTES

      rows = JSON.parse(path.read)
      rows = rows["players"] if rows.is_a?(Hash)
      rows.is_a?(Array) ? rows : []
    rescue JSON::ParserError, SystemCallError, EncodingError
      []
    end
    private_class_method :read

    def entry_from(row)
      return unless row.is_a?(Hash) && row["name"].is_a?(String) && row["picture"].is_a?(String)

      name = SlackProfiles::Sanitizer.display_name(row["name"])
      profile_name = SlackProfiles::Sanitizer.profile_name(row["name"])
      path = picture_path(row["picture"])
      Entry.new(name: name, profile_name: profile_name, picture_path: path.to_s) if name && profile_name && path
    end
    private_class_method :entry_from

    # Only a plain file name inside the directory (no path, no "..", no links out of it).
    def picture_path(file)
      return unless file.match?(PICTURE_FILE)

      path = directory.join(file)
      path if path.file? && !path.symlink?
    end
    private_class_method :picture_path
  end
end
