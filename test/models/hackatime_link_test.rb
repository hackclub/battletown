require "test_helper"

class HackatimeLinkTest < ActiveSupport::TestCase
  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
    @project = Project.create!(user: @user, name: "Space Farm", kind: "game")
    @second = Project.create!(user: @user, name: "Website")
  end

  def link(project = @project, name = "space-farm", user: project.user, method: "manual")
    HackatimeLink.new(project: project, user: user, hackatime_project: name, link_method: method)
  end

  test "links a Hackatime project by its exact name" do
    saved = link.tap(&:save!)
    assert_equal @project, HackatimeLink.project_for(@user, "space-farm")
    assert_equal [ "space-farm" ], @project.hackatime_project_names
    assert_nil HackatimeLink.project_for(@user, "Space-Farm"), "names match exactly"
    assert_equal "manual", saved.link_method
  end

  test "a Hackatime project links to at most one project per user" do
    link.save!
    duplicate = link(@second)
    assert_not duplicate.valid?
    assert_match(/already linked/, duplicate.errors.full_messages.to_sentence)
    assert_raises(ActiveRecord::RecordNotUnique) do
      HackatimeLink.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end
  end

  test "different users may link the same Hackatime project name" do
    link.save!
    theirs = Project.create!(user: @other, name: "Theirs")
    assert link(theirs).valid?
  end

  test "name length and characters are validated" do
    [ "", "  ", "x" * 121, "bad\nname", "tab\tname", "<script>", "'; DROP TABLE x;--", "-leading-symbol", "emoji \u{1F600}" ].each do |bad|
      assert_not link(@project, bad).valid?, bad.inspect
    end
    [ "x" * 120, "my-game", "my_game v2", "org/repo", "game.js", "Проект", "a (copy)", "c++" ].each do |good|
      assert link(@project, good).valid?, good
    end
  end

  test "link_method is limited to manual, auto_repo and confirmed" do
    assert_not link(@project, "a", method: "magic").valid?
    HackatimeLink::METHODS.each_with_index { |method, i| assert link(@project, "n#{i}", method: method).valid? }
  end

  test "a link must belong to the same user as its project" do
    assert_not link(@project, "x", user: @other).valid?
  end

  test "a project can link at most 20 Hackatime projects" do
    HackatimeLink::MAX_PER_PROJECT.times { |i| link(@project, "p#{i}").save! }
    assert_not link(@project, "one-more").valid?
  end

  test "the database rejects bad rows and cross-user links" do
    saved = link.tap(&:save!)
    assert_raises(ActiveRecord::CheckViolation) { HackatimeLink.transaction(requires_new: true) { saved.update_columns(link_method: "magic") } }
    assert_raises(ActiveRecord::CheckViolation) { HackatimeLink.transaction(requires_new: true) { saved.update_columns(hackatime_project: "") } }
    assert_raises(ActiveRecord::CheckViolation) { HackatimeLink.transaction(requires_new: true) { saved.update_columns(hackatime_project: "x" * 121) } }
    assert_raises(ActiveRecord::CheckViolation) { HackatimeLink.transaction(requires_new: true) { saved.update_columns(hackatime_project: "a\nb") } }
    assert_raises(ActiveRecord::CheckViolation) { HackatimeLink.transaction(requires_new: true) { saved.update_columns(hackatime_project: " padded ") } }
    assert_raises(ActiveRecord::InvalidForeignKey) { HackatimeLink.transaction(requires_new: true) { saved.update_columns(user_id: @other.id) } }
  end

  test "link suggestions: one per project and name, valid states only" do
    suggestion = @project.link_suggestions.create!(hackatime_project: "space-farm")
    assert suggestion.pending?
    assert_not @project.link_suggestions.build(hackatime_project: "space-farm").valid?
    assert @second.link_suggestions.build(hackatime_project: "space-farm").valid?
    assert_not LinkSuggestion.new(project: @project, hackatime_project: "other", state: "maybe").valid?
    assert_raises(ActiveRecord::CheckViolation) { LinkSuggestion.transaction(requires_new: true) { suggestion.update_columns(state: "maybe") } }
    assert_raises(ActiveRecord::RecordNotUnique) do
      LinkSuggestion.transaction(requires_new: true) { LinkSuggestion.new(project: @project, hackatime_project: "space-farm").save!(validate: false) }
    end
  end

  test "deleting a project removes its links and suggestions" do
    link.save!
    @project.link_suggestions.create!(hackatime_project: "other")
    @project.discard!
    assert_equal 0, HackatimeLink.where(project_id: @project.id).count
    assert_equal 0, LinkSuggestion.where(project_id: @project.id).count
  end
end
