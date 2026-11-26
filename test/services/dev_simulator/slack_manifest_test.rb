require "test_helper"
require_relative "../../support/dev_slack_manifest_support"

class DevSimulatorSlackManifestTest < ActiveSupport::TestCase
  include DevSlackManifestSupport

  teardown { drop_fake_manifest }

  test "reads the entries in file order, each with a sanitised name and a picture inside the directory" do
    dir = use_fake_manifest(%w[Zorblax Quimby])

    entries = DevSimulator::SlackManifest.entries
    assert_equal %w[Zorblax Quimby], entries.map(&:name)
    assert_equal %w[Zorblax Quimby], entries.map(&:profile_name)
    assert_equal [ File.join(dir, "player-01.webp"), File.join(dir, "player-02.webp") ], entries.map(&:picture_path)
  end

  test "no directory, no file or a malformed file is just an empty list" do
    use_empty_manifest_dir
    assert_equal [], DevSimulator::SlackManifest.entries

    [ "not json", "[1, 2]", "{\"players\": \"nope\"}", "null", "{" ].each do |body|
      File.write(File.join(@dev_slack_dir, "manifest.json"), body)
      assert_equal [], DevSimulator::SlackManifest.entries, body
    end
  end

  test "bad entries are skipped: no name, an unusable name, a missing picture, a path out of the directory, a duplicate name" do
    use_fake_manifest(%w[Zorblax], extra_rows: [
      { name: "", picture: "player-01.webp" }, { name: "   ", picture: "player-01.webp" }, { name: "Quimby", picture: "gone.webp" },
      { name: "Wexley", picture: "../player-01.webp" }, { name: "Ulrich", picture: "/etc/passwd" }, { name: "Tavish" },
      { picture: "player-01.webp" }, "text", { name: "zorblax", picture: "player-01.webp" }, { name: "Yarrow", picture: "player-01.webp" }
    ])

    assert_equal %w[Zorblax Yarrow], DevSimulator::SlackManifest.entries.map(&:name)
  end

  test "a picture that is a link out of the directory is refused" do
    use_fake_manifest(%w[Zorblax])
    outside = File.join(Dir.mktmpdir("dev-slack-outside"), "x.webp")
    File.binwrite(outside, picture_bytes(:webp, size: 128))
    File.symlink(outside, File.join(@dev_slack_dir, "linked.webp"))
    File.write(File.join(@dev_slack_dir, "manifest.json"), JSON.generate(players: [ { name: "Quimby", picture: "linked.webp" } ]))

    assert_equal [], DevSimulator::SlackManifest.entries
  ensure
    FileUtils.rm_rf(File.dirname(outside)) if outside
  end

  test "the default directory is under tmp and ignored by git" do
    ENV.delete("DEV_SLACK_DIR")
    assert_equal Rails.root.join("tmp", "dev_slack"), DevSimulator::SlackManifest.directory
    assert system("git", "-C", Rails.root.to_s, "check-ignore", "-q", "tmp/dev_slack/manifest.json")
  end

  test "nothing is read in production" do
    use_fake_manifest
    original = Rails.method(:env)
    Rails.define_singleton_method(:env) { ActiveSupport::EnvironmentInquirer.new("production") }
    assert_equal [], DevSimulator::SlackManifest.entries
  ensure
    Rails.define_singleton_method(:env, original)
  end
end
