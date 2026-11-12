require "test_helper"
require_relative "../support/ships_test_support"

class ShipTest < ActiveSupport::TestCase
  include ShipsTestSupport

  setup do
    @user = users(:onboarded)
    @project = make_project(@user)
    @other_user = users(:new_user)
  end

  def build_ship(**attrs)
    Ship.new({ user: @user, project: @project, status: "submitted", description: "Cows", repo_url: REPO, coded_seconds: 3600,
               window_start_date: Date.new(2026, 11, 9), window_end_date: Date.new(2026, 11, 9), daily_seconds: { "2026-11-09" => 3600 },
               submitted_at: Time.current }.merge(attrs))
  end

  test "a complete ship is valid and keeps its snapshot" do
    ship = build_ship
    assert ship.valid?, ship.errors.full_messages.to_sentence
    ship.save!
    assert_equal({ Date.new(2026, 11, 9) => 3600 }, ship.daily_seconds_by_date)
    assert_equal [ Date.new(2026, 11, 9) ], ship.window_dates
  end

  test "the description is required to submit (1 to 1000 characters) but not for a draft" do
    assert_not build_ship(description: "  ").valid?
    assert_not build_ship(description: "x" * 1001).valid?
    assert build_ship(description: "x" * 1000).valid?
    assert build_ship(status: "draft", description: nil, submitted_at: nil, repo_url: nil).valid?
  end

  test "the GitHub link is required to submit, must be a GitHub repo over https and is tidied" do
    assert_not build_ship(repo_url: nil).valid?
    [ "http://github.com/a/b", "https://gitlab.com/a/b", "https://github.com/a", "https://github.com/a/b/tree/main", "javascript:alert(1)", "https://github.com/#{'a' * 40}/x" ].each do |bad|
      assert_not build_ship(repo_url: bad).valid?, bad
    end
    ship = build_ship(repo_url: "https://www.GitHub.com/Octo/Space-Farm.git/")
    assert ship.valid?
    assert_equal REPO, ship.repo_url
  end

  test "the demo link is optional, https only and at most 300 characters" do
    assert build_ship(demo_url: nil).valid?
    assert build_ship(demo_url: "https://play.example.com/game").valid?
    [ "http://example.com", "ftp://example.com", "https://", "https://user:pw@example.com", "https://exa mple.com", "javascript:alert(1)", "https://example.com/#{'a' * 300}" ].each do |bad|
      assert_not build_ship(demo_url: bad).valid?, bad
    end
  end

  test "coded time and the window must be consistent" do
    assert_not build_ship(coded_seconds: 0, daily_seconds: {}).valid?
    assert_not build_ship(window_end_date: Date.new(2026, 11, 8)).valid?
    assert_not build_ship(daily_seconds: { "2026-11-09" => 1800 }).valid?, "the per-day seconds must add up to the coded time"
    assert_not build_ship(daily_seconds: { "2026-11-09" => 4200, "2026-11-10" => -600 }).valid?
  end

  test "approved seconds exist only on an approved ship, are above zero and never above the coded time" do
    approved = build_ship(status: "approved", approved_seconds: 1800, reviewed_at: Time.current)
    assert approved.valid?
    assert approved.tap { |ship| ship.approved_seconds = 3600 }.valid?
    assert_not approved.tap { |ship| ship.approved_seconds = 3601 }.valid?
    assert_not approved.tap { |ship| ship.approved_seconds = 0 }.valid?
    assert_not approved.tap { |ship| ship.approved_seconds = nil }.valid?
    assert_not build_ship(approved_seconds: 600).valid?, "a submitted ship has no approved hours"
  end

  test "a rejected ship needs a reason, up to 300 characters, and nothing else has one" do
    assert_not build_ship(status: "rejected", reviewed_at: Time.current).valid?
    assert_not build_ship(status: "rejected", reviewed_at: Time.current, rejection_reason: "x" * 301).valid?
    assert build_ship(status: "rejected", reviewed_at: Time.current, rejection_reason: "x" * 300).valid?
    assert_not build_ship(rejection_reason: "no").valid?
  end

  test "the project must belong to the user" do
    ship = build_ship(user: @other_user)
    assert_not ship.valid?
    assert_includes ship.errors.full_messages.to_sentence, "must be one of your projects"
  end

  test "one open ship per project, in the model and in the database" do
    build_ship.save!
    second = build_ship(status: "draft", submitted_at: nil, repo_url: nil)
    assert_not second.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { insert_ship_sql!(raw_ship_values(@user, @project)) }
    assert build_ship(status: "withdrawn").valid?, "finished ships do not count as open"
  end

  test "the snapshot cannot change after submission" do
    ship = build_ship.tap(&:save!)
    assert_not ship.update(coded_seconds: 7200, daily_seconds: { "2026-11-09" => 7200 })
    assert ship.errors.full_messages.to_sentence.include?("cannot change")
    draft = build_ship(status: "draft", submitted_at: nil).tap { |s| s.project = make_project(@user, name: "Other", hackatime: "other") }
    draft.save!
    assert draft.update(coded_seconds: 7200, daily_seconds: { "2026-11-09" => 7200 }, window_end_date: Date.new(2026, 11, 9))
  end

  test "the database refuses what the model refuses, even with raw SQL" do
    bad = {
      "unknown status" => { status: "lost" },
      "submitted without a description" => { description: "  " },
      "description over 1000" => { description: "x" * 1001 },
      "submitted without a repo" => { repo_url: nil },
      "repo not on GitHub" => { repo_url: "https://example.com/a/b" },
      "repo over http" => { repo_url: "http://github.com/a/b" },
      "demo over http" => { demo_url: "http://example.com" },
      "demo with a space" => { demo_url: "https://exa mple.com" },
      "no coded seconds" => { coded_seconds: 0 },
      "window ends before it starts" => { window_end_date: "2026-11-01" },
      "approved seconds on a submitted ship" => { approved_seconds: 100 },
      "approved without seconds" => { status: "approved", reviewed_at: "2026-11-10 13:00:00" },
      "approved seconds above coded" => { status: "approved", approved_seconds: 3601, reviewed_at: "2026-11-10 13:00:00" },
      "approved zero seconds" => { status: "approved", approved_seconds: 0, reviewed_at: "2026-11-10 13:00:00" },
      "approved without a review time" => { status: "approved", approved_seconds: 100 },
      "rejected without a reason" => { status: "rejected", reviewed_at: "2026-11-10 13:00:00" },
      "reason on a submitted ship" => { rejection_reason: "no" },
      "reason over 300" => { status: "rejected", rejection_reason: "x" * 301, reviewed_at: "2026-11-10 13:00:00" },
      "submitted without a submission time" => { submitted_at: nil },
      "payout note on a submitted ship" => { payout_note: "n" },
      "daily seconds not an object" => { daily_seconds: "[1]" }
    }
    bad.each do |label, overrides|
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::RecordNotUnique, label) do
        ActiveRecord::Base.transaction(requires_new: true) { insert_ship_sql!(raw_ship_values(@user, @project, **overrides)) }
      end
    end
    assert_equal 0, Ship.count
    assert_nothing_raised { ActiveRecord::Base.transaction(requires_new: true) { insert_ship_sql!(raw_ship_values(@user, @project)) } }
  end

  test "the database refuses a ship whose project belongs to someone else" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      ActiveRecord::Base.transaction(requires_new: true) { insert_ship_sql!(raw_ship_values(@other_user, @project)) }
    end
  end

  test "deleting the user deletes their ships, and the reviewer link is only cleared when a reviewer is deleted" do
    reviewer = User.create!(hca_uid: "ident!reviewer-#{SecureRandom.hex(4)}", display_name: "Reviewer")
    ship = build_ship(status: "approved", approved_seconds: 3600, reviewed_at: Time.current, reviewer: reviewer).tap(&:save!)

    reviewer.delete
    assert_nil ship.reload.reviewer_id
    assert_equal "approved", ship.status

    @user.delete
    assert_not Ship.exists?(ship.id)
  end

  test "deleting a project deletes its ships" do
    ship = build_ship.tap(&:save!)
    @project.destroy
    assert_not Ship.exists?(ship.id)
  end

  test "a project with a waiting or approved ship is not deletable, a rejected or withdrawn one is" do
    ship = build_ship.tap(&:save!)
    assert_not @project.deletable?
    ship.update!(status: "withdrawn")
    assert @project.deletable?
  end

  test "review order lists waiting ships oldest first, then the rest newest first" do
    other = make_project(@user, name: "B", hackatime: "b")
    third = make_project(@user, name: "C", hackatime: "c")
    done = build_ship(status: "approved", approved_seconds: 100, reviewed_at: Time.current, submitted_at: 5.days.ago).tap(&:save!)
    newer = Ship.create!(user: @user, project: other, status: "submitted", description: "d", repo_url: REPO, coded_seconds: 3600,
                         window_start_date: Date.new(2026, 11, 9), window_end_date: Date.new(2026, 11, 9), daily_seconds: { "2026-11-09" => 3600 }, submitted_at: 1.day.ago)
    older = Ship.create!(user: @user, project: third, status: "submitted", description: "d", repo_url: REPO, coded_seconds: 3600,
                         window_start_date: Date.new(2026, 11, 9), window_end_date: Date.new(2026, 11, 9), daily_seconds: { "2026-11-09" => 3600 }, submitted_at: 3.days.ago)
    assert_equal [ older, newer, done ], Ship.review_order.to_a
  end
end
