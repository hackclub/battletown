require "test_helper"
require_relative "../../support/fighters_helper"
require_relative "../../support/ships_test_support"

class Bosses::LiveTest < ActiveSupport::TestCase
  include FightersHelper
  include ShipsTestSupport
  include ActiveJob::TestHelper

  # Fields that must never be in what goes to every open dashboard.
  PRIVATE = %w[email hca_uid slack_id display_name real_name user_id damage_text seconds minutes].freeze

  setup do
    @today = Time.current.utc.to_date
    @boss = make_boss(starts_on: friday_on_or_before(@today), hp_seconds: 7_200)
    @stream = Bosses::Live.stream_for(@boss)
    @pubsub = ActionCable.server.pubsub
    @pubsub.clear
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @user = users(:onboarded)
  end

  teardown do
    Rails.cache = @original_cache
    @pubsub.clear
  end

  def sent = @pubsub.broadcasts(@stream).map { |raw| JSON.parse(raw) }

  def recent_fighter(key, name: nil)
    person = fighter(key, seconds: 1800, ago: 1.hour, now: Time.current, name: name)
    Rails.cache.clear
    @pubsub.clear
    clear_enqueued_jobs
    person
  end

  # ---- the payload ----

  test "the payload has what the stage shows everybody and nothing about a viewer or a private person" do
    named = recent_fighter("pub", name: "Sky")
    plain = recent_fighter("anon")
    Bosses::Live.publish(@boss)

    payload = sent.fetch(0)
    assert_equal %w[arena_text damage_text].sort & payload.keys, []
    assert_equal @boss.id, payload["boss_id"]
    assert_equal 100, payload["health_percent"]
    assert_equal "in_progress", payload["state"]
    assert_equal 2, payload["fighters"].size
    assert payload["at"].is_a?(Integer)
    assert_not payload["fighters"].any? { |fighter| fighter["you"] }, "nobody is marked `you` in a push"

    text = payload.to_json
    PRIVATE.each { |word| assert_no_match(/"#{word}"/, text) }
    [ named.email, named.hca_uid, named.slack_id, named.display_name ].each { |value| assert_not_includes text, value }
    assert_not_includes text, "private.example.org"
    handle = PublicProfile.handle_for(plain.public_slug)
    assert_equal [ handle, "Sky" ].sort, payload["fighters"].map { |fighter| fighter["name"] }.sort, "everybody is named: a chosen name or a generated handle"
    assert_equal [ "/players/#{plain.public_slug}", "/players/#{named.public_slug}" ].sort, payload["fighters"].map { |fighter| fighter["path"] }.sort
  end

  test "a push is the same people and health the poll serves, apart from the viewer" do
    recent_fighter("one", name: "Ada")
    live = Bosses::Presenter.new(user: nil).public_payload
    poll = Bosses::Presenter.new(user: @user).live_payload
    assert_equal poll[:fighters].map { |fighter| fighter.except(:you, :title, :label, :hint) },
                 live[:fighters].map { |fighter| fighter.except(:you, :title, :label, :hint) }
    assert_equal poll.slice(:state, :boss_name, :health_percent, :health_text, :summary, :total, :shippers),
                 live.slice(:state, :boss_name, :health_percent, :health_text, :summary, :total, :shippers)
  end

  test "the arena sentence of a push is the shared parts of the personal one" do
    presenter = Bosses::Presenter.new(user: nil)
    assert_equal presenter.arena_text, [ presenter.community_text, presenter.contributed_text, presenter.outcome_text ].compact.join(" ")
  end

  # ---- throttle ----

  test "changes inside five seconds broadcast once and schedule one trailing broadcast" do
    recent_fighter("a")
    3.times { Bosses::Live.hours_changed }
    assert_equal 1, sent.size
    assert_enqueued_jobs 1, only: BroadcastBossStageJob

    perform_enqueued_jobs
    assert_equal 2, sent.size, "the trailing broadcast carries what changed meanwhile"
    3.times { Bosses::Live.hours_changed }
    assert_equal 2, sent.size, "the window the trailing one opened throttles again"
  end

  test "a change after the window broadcasts again" do
    recent_fighter("a")
    Bosses::Live.hours_changed
    travel 6.seconds do
      Bosses::Live.hours_changed
    end
    assert_equal 2, sent.size
  end

  test "nothing happens between bosses" do
    @boss.destroy!
    assert_nothing_raised { Bosses::Live.hours_changed }
    assert_empty @pubsub.broadcasts(@stream)
    assert_no_enqueued_jobs
  end

  test "flush_pending sends what was waiting for the trailing job" do
    recent_fighter("a")
    Bosses::Live.hours_changed
    Bosses::Live.hours_changed # inside the window: marked
    assert_equal 1, sent.size
    stub_method(ActionCable.server.pubsub, :shutdown, -> { }) { Bosses::Live.flush_pending }
    assert_equal 2, sent.size
  end

  # ---- the ledger ----

  test "writing coded time broadcasts after the commit, never inside the transaction" do
    inside = nil
    HourEntry.transaction do
      HourEntry.create!(user: @user, local_date: @today, seconds: 1800, source: "manual", note: "test", idempotency_key: SecureRandom.hex(8))
      inside = sent.size
    end
    assert_equal 0, inside
    assert_equal 1, sent.size
  end

  test "a broadcast that fails never fails the ledger write" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("boss_live_failed.battletown") { |*, payload| events << payload }
    stub_method(ActionCable.server, :broadcast, ->(*) { raise "cable down" }) do
      assert_difference -> { HourEntry.count }, 1 do
        HourEntry.create!(user: @user, local_date: @today, seconds: 1800, source: "manual", note: "test", idempotency_key: SecureRandom.hex(8))
      end
    end
    assert_equal [ "RuntimeError" ], events.map { |event| event[:error_class] }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # ---- ships ----

  def submit_real_ship(user, seconds, at: Time.current)
    project = make_project(user, name: "Live #{SecureRandom.hex(3)}", hackatime: "live-#{SecureRandom.hex(3)}")
    code(user, at.utc.to_date, seconds, hackatime: project.hackatime_links.first.hackatime_project)
    Rails.cache.clear
    @pubsub.clear
    Ships::Submit.call(project: project, attributes: ship_attrs, submit: true, now: at)
  end

  test "submitting a ship broadcasts the new stage once" do
    submit_real_ship(@user, 3_600)
    assert_equal 1, sent.size
    assert_equal 50, sent.first["health_percent"]
  end

  test "a defeating ship broadcasts at once, even inside the window, and the push says defeated" do
    Rails.cache.write("bosses/live/lock/#{@boss.id}", 1, expires_in: 5.seconds)
    project = make_project(@user, name: "Big", hackatime: "big")
    code(@user, @today, 7_400, hackatime: "big")
    @pubsub.clear
    Ships::Submit.call(project: project, attributes: ship_attrs, submit: true, now: Time.current)

    assert_predicate @boss.reload, :defeated?
    assert_equal 1, sent.size
    assert_equal "defeated", sent.first["state"]
    assert_equal 0, sent.first["health_percent"]
    assert_includes sent.first["outcome_text"], "Boss defeated."
  end

  test "a broadcast error does not break the ship" do
    ship = nil
    stub_method(ActionCable.server, :broadcast, ->(*) { raise "cable down" }) { ship = submit_real_ship(@user, 3_600) }
    assert_predicate ship, :persisted?
    assert_predicate ship, :status_submitted?
  end

  test "a draft does not broadcast" do
    project = make_project(@user, name: "Draft", hackatime: "draft-one")
    code(@user, @today, 3_600, hackatime: "draft-one")
    @pubsub.clear
    Ships::Submit.call(project: project, attributes: ship_attrs, submit: false)
    assert_empty sent
  end

  # ---- the kill switch ----

  test "with the kill switch on, nothing is pushed but pages are told to go back to polling" do
    with_feature(:live_updates_paused) do
      Bosses::Live.hours_changed
      assert_equal [ { "type" => "paused" } ], sent
    end
  end
end
