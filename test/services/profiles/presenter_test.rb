require "test_helper"
require_relative "../../support/profiles_helper"

class ProfilesPresenterTest < ActiveSupport::TestCase
  include ProfilesHelper

  NOW = Time.utc(2026, 11, 15, 12)

  setup do
    travel_to NOW
    @boss = make_boss
    @owner = make_player("presented", name: "Pres")
    @viewer = users(:onboarded)
  end

  teardown { travel_back }

  def presenter(viewer: @viewer) = Profiles::Presenter.new(user: @owner, viewer: viewer, now: NOW)

  test "name, initial, tone and since line come from the chosen name and the opaque address" do
    profile = presenter
    assert_equal "Pres", profile.name
    assert_equal "P", profile.initial
    assert_equal @owner.public_slug, profile.slug
    assert_includes 0...Profiles::Presenter::TONES, profile.tone
    assert_equal profile.tone, presenter.tone, "the colour never changes for the same address"
    assert_equal "Fighting since September 2026", profile.since_text
    assert_not profile.own?
    assert presenter(viewer: @owner).own?
  end

  test "someone who chose no name is shown by a generated handle, never their real name, and always has an address" do
    profile = Profiles::Presenter.new(user: @viewer, viewer: @viewer, now: NOW)
    assert_equal PublicProfile.handle_for(@viewer.public_slug), profile.name
    assert_not_equal "Veteran", profile.name
    assert_equal @viewer.public_slug, profile.slug
  end

  test "the Slack name is the name when none was chosen, and the Slack picture is the avatar" do
    SlackProfile.create!(user_id: @viewer.id, display_name: "Vet Slack", picture: "x", picture_sha256: "a" * 64, picture_bytes: 1, status: "ok")
    profile = Profiles::Presenter.new(user: @viewer, viewer: @viewer, now: NOW)
    assert_equal "Vet Slack", profile.name
    assert_equal "V", profile.initial
    assert_equal "/players/#{@viewer.public_slug}/avatar?v=#{'a' * 10}", profile.avatar_url
  end

  test "damage numbers are Bosses::Damage's" do
    ship_for(make_project(@owner, "A"), seconds: 5400, on: Date.new(2026, 11, 15))
    ship_for(make_project(@owner, "B"), seconds: 600, on: Date.new(2026, 11, 2), status: "approved")
    profile = presenter
    assert_equal @boss.name, profile.boss_name
    assert_equal Bosses::Damage.for_user(@boss, @owner), profile.week_damage_seconds
    assert_equal 5400, profile.week_damage_seconds
    assert_equal Bosses::Damage.all_time_for_user(@owner), profile.all_time_damage_seconds
    assert_equal 6000, profile.all_time_damage_seconds
  end

  test "between bosses the week damage is zero but all-time still counts" do
    ship_for(make_project(@owner, "A"), seconds: 600, on: Date.new(2026, 11, 15))
    @boss.destroy!
    profile = presenter
    assert_nil profile.boss_name
    assert_equal 0, profile.week_damage_seconds
    assert_equal 600, profile.all_time_damage_seconds
  end

  test "only plain values come out: no ActiveRecord objects" do
    make_project(@owner, "A", repo_url: "https://github.com/octo/a")
    ship_for(make_project(@owner, "B"), on: Date.new(2026, 11, 15))
    profile = presenter(viewer: @owner)
    values = [ profile.name, profile.initial, profile.slug, profile.tone, profile.since_text, profile.week_damage_seconds, profile.all_time_damage_seconds,
               profile.bosses_slain, profile.streak_days, *profile.projects, *profile.ships ]
    values.each { |value| assert_not_kind_of ActiveRecord::Base, value }
    assert_kind_of Data, profile.projects.first
  end

  test "ships are listed for the owner only" do
    ship_for(make_project(@owner, "A"), status: "rejected")
    assert_equal 1, presenter(viewer: @owner).ships.size
    assert_empty presenter.ships
  end

  test "projects are capped and newest first" do
    stub = Profiles::Presenter::PROJECT_LIMIT
    assert_equal 20, stub
    3.times { |i| make_project(@owner, "P#{i}", created_at: (3 - i).days.ago) }
    assert_equal %w[P2 P1 P0], presenter.projects.map(&:name)
  end

  test "queries do not grow with the number of projects and ships" do
    make_project(@owner, "First")
    baseline = count_queries { fresh = presenter(viewer: @owner); fresh.projects; fresh.ships; fresh.week_damage_seconds; fresh.all_time_damage_seconds; fresh.bosses_slain; fresh.streak_days }
    8.times { |i| ship_for(make_project(@owner, "Q#{i}"), on: Date.new(2026, 11, 13 + (i % 4)), status: "approved") }
    more = count_queries { fresh = presenter(viewer: @owner); fresh.projects; fresh.ships; fresh.week_damage_seconds; fresh.all_time_damage_seconds; fresh.bosses_slain; fresh.streak_days }
    assert_equal baseline, more
    assert_operator more, :<=, 20
  end
end
