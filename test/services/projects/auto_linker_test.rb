require "test_helper"

class Projects::AutoLinkerTest < ActiveSupport::TestCase
  setup do
    @user = users(:onboarded)
    @game = Project.create!(user: @user, name: "Space Farm", kind: "game", repo_url: "https://github.com/octo/space-farm")
    @site = Project.create!(user: @user, name: "Portfolio Site", kind: "website")
    @events = []
    @subscriber = ActiveSupport::Notifications.subscribe(Projects::LinkSuggestions::EVENT) { |event| @events << event.payload }
  end

  teardown { ActiveSupport::Notifications.unsubscribe(@subscriber) }

  def run_linker(*candidates, **options) = Projects::AutoLinker.call(@user, candidates, **options)

  test "an exact repo match links automatically as auto_repo" do
    result = run_linker({ name: "hackatime-farm", repo_url: "https://github.com/octo/space-farm" })
    assert_equal 1, result.linked.size
    link = result.linked.first
    assert_equal @game, link.project
    assert_equal "auto_repo", link.link_method
    assert_equal "hackatime-farm", link.hackatime_project
    assert_empty result.suggested
    assert_empty @events
  end

  test "the repo URL is normalised on both sides" do
    @game.update!(repo_url: "https://github.com/Octo/Space-Farm.git")
    [ "http://www.github.com/OCTO/space-farm/", "https://github.com/octo/space-farm.git", "HTTP://GITHUB.COM/octo/space-farm" ].each_with_index do |spelling, i|
      @game.hackatime_links.destroy_all
      result = run_linker({ name: "x#{i}", repo_url: spelling })
      assert_equal 1, result.linked.size, spelling
    end
  end

  test "near-miss repo URLs never link" do
    [ "https://github.com/octo/space-farm-2", "https://github.com/octo/space", "https://github.com/other/space-farm",
      "https://github.com/octo/space-farm/tree/main", "https://gitlab.com/octo/space-farm", "https://github.com/octo", "", nil ].each do |url|
      result = run_linker({ name: "zzz-unrelated", repo_url: url })
      assert_empty result.linked, url.inspect
    end
    assert_equal 0, HackatimeLink.count
  end

  test "a project without a repo never auto-links, even if the candidate has one" do
    result = run_linker({ name: "portfolio", repo_url: "https://github.com/octo/portfolio" })
    assert_empty result.linked
  end

  test "a close name makes a pending suggestion and fires the event, but never links" do
    result = run_linker({ name: "space-farm-dev", repo_url: nil })
    assert_empty result.linked
    suggestion = result.suggested.sole
    assert_equal @game, suggestion.project
    assert suggestion.pending?
    assert_equal 0, HackatimeLink.count
    assert_equal [ { suggestion_id: suggestion.id } ], @events
  end

  test "name closeness: normalised equality or containment, shorter side at least 4 characters" do
    close = Projects::AutoLinker.method(:close_names?)
    assert close.call("Space Farm", "space_farm")
    assert close.call("Space Farm", "SPACE-FARM-v2")
    assert close.call("My Portfolio Site", "portfolio")
    assert close.call("Space Farm", "farm"), "farm is exactly 4 characters: allowed"
    assert_not close.call("Space Farm", "far")
    assert_not close.call("abc", "abc")
    assert_not close.call("Space Farm", "Moon Base")
    assert_not close.call("", "")
  end

  test "an unrelated name does nothing" do
    result = run_linker({ name: "homework", repo_url: nil })
    assert_empty result.linked
    assert_empty result.suggested
    assert_equal 0, LinkSuggestion.count
  end

  test "a repo match beats a name match, and the other project is not asked about it" do
    result = run_linker({ name: "portfolio-site", repo_url: "https://github.com/octo/space-farm" })
    assert_equal [ @game ], result.linked.map(&:project)
    assert_empty result.suggested
  end

  test "a declined suggestion is skipped and never re-asked" do
    first = run_linker({ name: "space-farm-dev" }).suggested.sole
    Projects::LinkSuggestions.decline!(first)
    @events.clear
    result = run_linker({ name: "space-farm-dev" })
    assert_empty result.suggested
    assert_empty result.linked
    assert_empty @events
    assert first.reload.declined?
  end

  test "a declined name is not auto-linked by repo either" do
    @game.link_suggestions.create!(hackatime_project: "hackatime-farm", state: "declined")
    assert_empty run_linker({ name: "hackatime-farm", repo_url: "https://github.com/octo/space-farm" }).linked
  end

  test "an existing pending suggestion is not duplicated or re-announced" do
    run_linker({ name: "space-farm-dev" })
    @events.clear
    assert_empty run_linker({ name: "space-farm-dev" }).suggested
    assert_equal 1, LinkSuggestion.count
    assert_empty @events
  end

  test "Hackatime projects already linked to any of the user's projects are skipped" do
    @site.hackatime_links.create!(user_id: @user.id, hackatime_project: "space-farm-dev", link_method: "manual")
    result = run_linker({ name: "space-farm-dev", repo_url: "https://github.com/octo/space-farm" })
    assert_empty result.linked
    assert_empty result.suggested
    assert_equal @site, HackatimeLink.project_for(@user, "space-farm-dev")
  end

  test "a name that fits two projects equally is ambiguous: no suggestion" do
    Project.create!(user: @user, name: "Farm Dev", kind: "game")
    assert_empty run_linker({ name: "space-farm-dev" }).suggested
  end

  test "exact name equality beats containment" do
    other = Project.create!(user: @user, name: "Farm Game Deluxe")
    result = run_linker({ name: "farm game deluxe" })
    assert_equal [ other ], result.suggested.map(&:project)
  end

  test "two projects on the same repo is ambiguous: no auto link" do
    Project.create!(user: @user, name: "Fork", repo_url: "https://github.com/octo/space-farm")
    assert_empty run_linker({ name: "zzz-other", repo_url: "https://github.com/octo/space-farm" }).linked
  end

  test "archived projects and other users' projects are ignored" do
    @game.archive!
    assert_empty run_linker({ name: "space-farm", repo_url: "https://github.com/octo/space-farm" }).linked
    foreign = Project.create!(user: users(:new_user), name: "Space Farm", repo_url: "https://github.com/octo/space-farm")
    assert_empty run_linker({ name: "space-farm" }, projects: [ foreign ]).linked
    assert_empty LinkSuggestion.where(project: foreign)
  end

  test "candidates with invalid names or string keys are handled, and the call is idempotent" do
    candidates = [ { "name" => "space-farm-dev", "repo_url" => nil }, { name: "bad\nname" }, { name: "" }, { name: nil }, "nonsense", nil ]
    assert_equal 1, run_linker(*candidates).suggested.size
    assert_empty run_linker(*candidates).suggested
    assert_equal 1, LinkSuggestion.count
  end

  test "a Hackatime project is linked to at most one project even with repeated candidates" do
    result = run_linker({ name: "dup", repo_url: "https://github.com/octo/space-farm" }, { name: "dup", repo_url: "https://github.com/octo/space-farm" })
    assert_equal 1, result.linked.size
    assert_equal 1, HackatimeLink.where(user_id: @user.id, hackatime_project: "dup").count
  end
end
