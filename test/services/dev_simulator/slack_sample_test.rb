require "test_helper"
require_relative "../../support/bosses_helper"
require_relative "../../support/dev_simulator_test_support"
require_relative "../../support/dev_slack_manifest_support"

# DevSimulator::SlackSample and DevSimulator::SlackMembers with a stubbed Slack: invented ids, names and pictures, no network.
class DevSimulatorSlackSampleTest < ActiveSupport::TestCase
  include DevSimulatorTestSupport
  include DevSlackManifestSupport

  # Answers users.info from a table of id => [display_name, custom picture?], like SlackProfiles::Client would.
  class FakeClient
    attr_reader :asked

    def initialize(table) = (@table = table; @asked = [])

    def user_info(id)
      @asked << id
      row = @table[id] or return SlackProfiles::Client::Result.failure("not_found")
      name, custom = row
      SlackProfiles::Client::Result.new(ok: true, error_code: nil, name: name, image_url: (custom ? "https://avatars.slack-edge.com/x/#{id}_512.png" : nil), retry_after: nil)
    end
  end

  setup do
    local_database!
    use_empty_manifest_dir
    @png = picture_bytes(:png, size: 300)
    @download = SlackProfiles::Download.method(:call)
    png = @png
    SlackProfiles::Download.define_singleton_method(:call) { |_url, **| png }
    @people = { "U0FAKE0001" => [ "Zorblax", true ], "U0FAKE0002" => [ "Quimby Fullsurname", true ], "U0FAKE0003" => [ "", true ],
                "U0FAKE0004" => [ "Nopicture", false ], "U0FAKE0005" => [ "Amber", true ], "U0FAKE0006" => [ "Armand", true ],
                "U0FAKE0007" => [ "Fennimore", true ], "U0FAKE0008" => [ "zorblax", true ], "U0FAKE0009" => [ "Tavish", true ] }
    @client = FakeClient.new(@people)
  end

  teardown do
    SlackProfiles::Download.define_singleton_method(:call, @download)
    restore_database_host!
    drop_fake_manifest
  end

  def sample(**options) = DevSimulator::SlackSample.call(client: @client, pause: 0, directory: @dev_slack_dir, **options)

  test "writes a manifest of names and 128 px WebP files only: no Slack ids, no full names, no owner, nobody without a name or picture" do
    File.write(File.join(@dev_slack_dir, "members.json"), JSON.generate(members: @people.keys + [ "U0FAKE0099" ]))

    report = sample(count: 24, random: Random.new(1))

    assert_equal [ 10, 10, 4 ], [ report.members, report.tried, report.written ]
    raw = File.read(File.join(@dev_slack_dir, "manifest.json"))
    assert_no_match(/U0FAKE/, raw)
    names = JSON.parse(raw)["players"].map { |row| row["name"] }
    assert_equal %w[fennimore quimby tavish zorblax], names.map(&:downcase).sort
    assert_not_includes names.map(&:downcase), "amber"
    assert_not_includes names.map(&:downcase), "armand"
    assert_not_includes names.join, "Fullsurname"
    assert_equal 1, names.count { |name| name.casecmp?("zorblax") }
    JSON.parse(raw)["players"].each do |row|
      assert_match(/\Aplayer-\d\d\.webp\z/, row["picture"])
      image = Vips::Image.new_from_buffer(File.binread(File.join(@dev_slack_dir, row["picture"])), "")
      assert_equal [ 128, 128 ], [ image.width, image.height ]
    end
    assert_equal names.sort, DevSimulator::SlackManifest.entries.map(&:name).sort
  end

  test "stops after COUNT usable people, and a re-sample replaces the old files" do
    File.write(File.join(@dev_slack_dir, "members.json"), JSON.generate(@people.keys))

    first = sample(count: 2, random: Random.new(3))
    assert_equal 2, first.written
    assert_equal 2, Dir.glob(File.join(@dev_slack_dir, "player-*.webp")).size

    FileUtils.touch(File.join(@dev_slack_dir, "player-09.webp"))
    sample(count: 3, random: Random.new(4))
    assert_equal 3, Dir.glob(File.join(@dev_slack_dir, "player-*.webp")).size
    assert_equal 3, DevSimulator::SlackManifest.entries.size
  end

  test "ids listed under exclude, in DEV_SLACK_EXCLUDE, and malformed ids are never asked about" do
    File.write(File.join(@dev_slack_dir, "members.json"), JSON.generate(members: @people.keys + [ "bad id", 12, nil ], exclude: [ "U0FAKE0001" ]))
    ENV["DEV_SLACK_EXCLUDE"] = "U0FAKE0009, U0FAKE0007"

    sample(count: 24, random: Random.new(1))

    assert_empty @client.asked & %w[U0FAKE0001 U0FAKE0009 U0FAKE0007]
    assert_equal 6, @client.asked.size
  ensure
    ENV.delete("DEV_SLACK_EXCLUDE")
  end

  test "the member list comes from the channel when there is no members file, and the people from the guarded pipeline" do
    members = DevSimulator::SlackMembers
    original = members.method(:call)
    members.define_singleton_method(:call) { |channel, **| channel == "ambers-mountain" ? %w[U0FAKE0001 U0FAKE0009] : [] }

    report = sample(count: 5)
    assert_equal [ 2, 2 ], [ report.members, report.written ]
  ensure
    members.define_singleton_method(:call, original)
  end

  test "a picture that is not an image or comes from a refused host is skipped" do
    File.write(File.join(@dev_slack_dir, "members.json"), JSON.generate(%w[U0FAKE0001 U0FAKE0009]))
    SlackProfiles::Download.define_singleton_method(:call) { |_url, **| raise SlackProfiles::Download::Refused, "host_not_allowed" }

    error = assert_raises(DevSimulator::SlackSample::Failed) { sample(count: 2) }
    assert_match(/None of the 2 members/, error.message)
    assert_not File.exist?(File.join(@dev_slack_dir, "manifest.json"))
  end

  test "no members and Slack setup problems are plain failures that name what is missing, never a token" do
    assert_raises(DevSimulator::SlackSample::Failed) { sample(count: 2, members: []) }

    failing = Object.new
    failing.define_singleton_method(:user_info) { |_id| SlackProfiles::Client::Result.failure("missing_scope") }
    error = assert_raises(DevSimulator::SlackSample::Failed) { sample(count: 2, members: [ "U0FAKE0001" ], client: failing) }
    assert_match(/missing_scope/, error.message)

    members = DevSimulator::SlackMembers
    original = members.method(:call)
    members.define_singleton_method(:call) { |_channel, **| raise DevSimulator::SlackMembers::Failed, "missing_scope" }
    error = assert_raises(DevSimulator::SlackSample::Failed) { sample(count: 2) }
    assert_match(/channels:read/, error.message)
    members.define_singleton_method(:call, original)
  end

  test "bounds on COUNT" do
    [ 0, 201, "x" ].each { |bad| assert_raises(DevSimulator::Refused) { sample(count: bad, members: [ "U0FAKE0001" ]) } }
  end

  test "SlackMembers pages through a channel, finds a channel by name, and turns Slack errors into short codes" do
    calls = []
    http = lambda do |method_name, params|
      calls << [ method_name, params ]
      case method_name
      when "conversations.list" then { "ok" => true, "channels" => [ { "id" => "C0FAKE00001", "name" => "other" }, { "id" => "C0FAKE00002", "name" => "fake-room" } ] }
      when "conversations.members"
        params[:cursor] ? { "ok" => true, "members" => %w[U0FAKE0002 U0FAKE0001] } : { "ok" => true, "members" => %w[U0FAKE0001], "response_metadata" => { "next_cursor" => "abc" } }
      end
    end

    assert_equal %w[U0FAKE0001 U0FAKE0002], DevSimulator::SlackMembers.call("#fake-room", token: "x", http: http)
    assert_equal "C0FAKE00002", calls.find { |name, _| name == "conversations.members" }.last[:channel]

    denied = ->(_method, _params) { { "ok" => false, "error" => "missing_scope" } }
    assert_equal "missing_scope", assert_raises(DevSimulator::SlackMembers::Failed) { DevSimulator::SlackMembers.call("C0FAKE00002", token: "x", http: denied) }.message
    weird = ->(_method, _params) { { "ok" => false, "error" => "Free text with SECRET" } }
    assert_equal "unknown_error", assert_raises(DevSimulator::SlackMembers::Failed) { DevSimulator::SlackMembers.call("C0FAKE00002", token: "x", http: weird) }.message
    assert_equal "channel_not_found", assert_raises(DevSimulator::SlackMembers::Failed) { DevSimulator::SlackMembers.call("nope", token: "x", http: http) }.message
    assert_equal "no_token", assert_raises(DevSimulator::SlackMembers::Failed) { DevSimulator::SlackMembers.call("nope", token: "") }.message
  end
end
