require "tmpdir"
require_relative "slack_profiles_helper"

# A fake local Slack manifest in a temp directory (DEV_SLACK_DIR points the loader there, so a test never reads or writes the real
# tmp/dev_slack). Names, pictures and ids here are invented: nothing in a test is a real person.
module DevSlackManifestSupport
  include SlackProfilesHelper

  FAKE_NAMES = %w[Zorblax Quimby Fennimore Tavish Yarrow Wexley Ulrich Pemberton].freeze

  def use_fake_manifest(names = FAKE_NAMES.first(3), extra_rows: [])
    @dev_slack_original = ENV["DEV_SLACK_DIR"]
    @dev_slack_dir = Dir.mktmpdir("dev-slack-test")
    ENV["DEV_SLACK_DIR"] = @dev_slack_dir
    rows = names.each_with_index.map do |name, index|
      file = format("player-%02d.webp", index + 1)
      File.binwrite(File.join(@dev_slack_dir, file), picture_bytes(:webp, size: 128, color: [ 30 + index * 40, 90, 200 ]))
      { name: name, picture: file }
    end
    File.write(File.join(@dev_slack_dir, "manifest.json"), JSON.generate(players: rows + extra_rows))
    @dev_slack_dir
  end

  def drop_fake_manifest
    ENV["DEV_SLACK_DIR"] = @dev_slack_original
    FileUtils.rm_rf(@dev_slack_dir) if @dev_slack_dir
  end

  # Point the loader at a directory with nothing in it.
  def use_empty_manifest_dir
    @dev_slack_original = ENV["DEV_SLACK_DIR"]
    @dev_slack_dir = Dir.mktmpdir("dev-slack-test")
    ENV["DEV_SLACK_DIR"] = @dev_slack_dir
  end
end
