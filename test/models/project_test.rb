require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  setup do
    @user = users(:onboarded)
    @other = users(:new_user)
  end

  def build(attrs = {}) = Project.new({ user: @user, name: "Space Farm", kind: "game" }.merge(attrs))

  test "a valid project saves and the first one becomes active" do
    project = build
    assert project.save
    assert project.active?
    assert_equal project, @user.active_project
    assert_not build(name: "Second").tap(&:save!).active?
  end

  test "name is required and at most 60 characters" do
    assert_not build(name: "").valid?
    assert_not build(name: "   ").valid?
    assert_not build(name: "x" * 61).valid?
    assert build(name: "x" * 60).valid?
    assert_equal "Space Farm", build(name: "  Space   Farm ").tap(&:valid?).name
  end

  test "kind must be on the allowlist" do
    assert_not build(kind: "spaceship").valid?
    Project::KINDS.each { |kind| assert build(kind: kind).valid?, kind }
  end

  test "idea is limited to 500 characters and blank becomes nil" do
    assert_not build(idea: "x" * 501).valid?
    assert build(idea: "x" * 500).valid?
    assert_nil build(idea: "  ").tap(&:valid?).idea
  end

  test "guide_key is nil, sd or playground" do
    [ nil, "", "sd", "playground" ].each { |key| assert build(guide_key: key).valid?, key.inspect }
    assert_not build(guide_key: "other").valid?
  end

  test "repo_url must be a GitHub repository over https and is normalised" do
    {
      "https://github.com/Octo/Cat" => "https://github.com/octo/cat",
      "https://www.github.com/octo/cat.git/" => "https://github.com/octo/cat",
      "  https://GitHub.com/octo/my.repo_1  " => "https://github.com/octo/my.repo_1"
    }.each do |input, expected|
      project = build(repo_url: input)
      assert project.valid?, input
      assert_equal expected, project.repo_url
    end
    [ "http://github.com/octo/cat", "github.com/octo/cat", "https://gitlab.com/octo/cat", "https://github.com/octo",
      "https://github.com/octo/cat/tree/main", "https://github.com/octo/cat?x=1", "https://github.com/octo/..",
      "https://github.com.evil.com/octo/cat", "javascript:alert(1)", "https://github.com/octo/cat dog",
      "https://github.com/#{'a' * 300}/cat" ].each do |bad|
      assert_not build(repo_url: bad).valid?, bad
    end
    assert_nil build(repo_url: "").tap(&:valid?).repo_url
  end

  test "demo_url must be an https link and is limited to 300 characters" do
    assert build(demo_url: "https://Example.com/play?level=1#top").tap(&:valid?).valid?
    assert_equal "https://example.com/play", build(demo_url: "https://EXAMPLE.com/play").tap(&:valid?).demo_url
    [ "http://example.com", "ftp://example.com", "javascript:alert(1)", "https://", "https://example", "example.com",
      "https://user:pw@example.com", "https://exa mple.com", "https://example.com/#{'a' * 300}" ].each do |bad|
      assert_not build(demo_url: bad).valid?, bad
    end
  end

  test "a user can have at most 10 projects" do
    Project::MAX_PER_USER.times { |i| Project.create!(user: @other, name: "P#{i}") }
    extra = Project.new(user: @other, name: "One too many")
    assert_not extra.valid?
    assert_match(/up to 10 projects/, extra.errors.full_messages.to_sentence)
    assert build.valid?, "other users are unaffected"
  end

  test "make_active! switches the one active project" do
    first = Project.create!(user: @user, name: "First")
    second = Project.create!(user: @user, name: "Second")
    assert first.reload.active?
    assert second.make_active!
    assert_equal [ second.id ], @user.projects.where(active: true).pluck(:id)
    assert_not first.reload.active?
  end

  test "archived projects cannot be activated and archiving the active one promotes another" do
    first = Project.create!(user: @user, name: "First")
    second = Project.create!(user: @user, name: "Second")
    first.archive!
    assert first.reload.status_archived?
    assert_not first.active?
    assert second.reload.active?, "the newest remaining live project takes over"
    assert_not first.make_active!
    assert_not first.reload.active?
  end

  test "archiving the last live project leaves nothing active and unarchiving restores it" do
    only = Project.create!(user: @user, name: "Only")
    only.archive!
    assert_nil @user.active_project
    only.unarchive!
    assert only.reload.active?
  end

  test "discard! deletes the project and hands the active flag on" do
    first = Project.create!(user: @user, name: "First")
    second = Project.create!(user: @user, name: "Second")
    first.discard!
    assert_not Project.exists?(first.id)
    assert second.reload.active?
  end

  test "default_name uses the first sentence of the idea, else the kind" do
    assert_equal "A farming game", Project.default_name(kind: "game", idea: "a farming game. With cows!")
    assert_equal "A farming game where the cows", Project.default_name(kind: "game", idea: "A farming game where the cows are in space. Very much WIP.")
    assert_equal "My app", Project.default_name(kind: "app", idea: nil)
    assert_equal "My project", Project.default_name(kind: "undecided", idea: "  ")
    assert_operator Project.default_name(kind: "game", idea: "word " * 40).length, :<=, 40
  end

  test "onboarding sync creates one project, updates it, and keeps a name the user chose" do
    @other.update!(project_kind: "game", project_idea: "A farming game")
    assert Project.sync_first_from_onboarding(@other)
    project = @other.projects.sole
    assert_equal "A farming game", project.name
    assert project.active?

    @other.update!(project_kind: "app", project_idea: "A budgeting app")
    assert Project.sync_first_from_onboarding(@other)
    assert_equal "A budgeting app", project.reload.name
    assert_equal "app", project.kind

    project.update!(name: "Budget Buddy")
    @other.update!(project_idea: "Something else")
    Project.sync_first_from_onboarding(@other)
    assert_equal "Budget Buddy", project.reload.name
    assert_equal 1, @other.projects.count
  end

  # --- database constraints: bypass the model with update_columns / raw SQL ---

  def assert_rejected(project, attrs)
    error = assert_raises(ActiveRecord::StatementInvalid, "#{attrs.inspect} should be rejected") do
      Project.transaction(requires_new: true) { project.update_columns(attrs) }
    end
    assert_kind_of ActiveRecord::CheckViolation, error
  end

  test "the database rejects what the model would" do
    project = Project.create!(user: @user, name: "Raw")
    assert_rejected project, name: ""
    assert_rejected project, name: "   "
    assert_rejected project, name: "x" * 61
    assert_rejected project, kind: "spaceship"
    assert_rejected project, idea: "x" * 501
    assert_rejected project, status: "deleted"
    assert_rejected project, guide_key: "nope"
    [ "http://github.com/a/b", "https://github.com/a", "https://github.com/a/b/c", "https://github.com/A/b", "https://gitlab.com/a/b",
      "https://github.com/a/..", "https://github.com/a/b.git/ x", "https://github.com/#{'a' * 40}/b" ].each { |bad| assert_rejected project, repo_url: bad }
    [ "http://x.com", "https://", "https://exa mple.com", "https://a@b.com", "https://x.com/#{'a' * 300}", "javascript:alert(1)" ].each { |bad| assert_rejected project, demo_url: bad }
    project.update_columns(repo_url: "https://github.com/a/b", demo_url: "https://x.com/y?z=1", guide_key: "sd", idea: "x" * 500)
    Project::KINDS.each { |kind| project.update_columns(kind: kind) }
  end

  test "an archived project cannot be flagged active even through raw SQL" do
    project = Project.create!(user: @user, name: "Raw")
    assert_rejected project, status: "archived"
    project.update_columns(active: false, status: "archived")
    assert_rejected project, active: true
  end

  test "the database allows only one active project per user" do
    Project.create!(user: @user, name: "A")
    second = Project.create!(user: @user, name: "B")
    assert_raises(ActiveRecord::RecordNotUnique) do
      Project.transaction(requires_new: true) { second.update_columns(active: true) }
    end
    Project.create!(user: @other, name: "Other user is unaffected")
  end

  test "raw SQL cannot bypass the constraints either" do
    assert_raises(ActiveRecord::CheckViolation) do
      Project.transaction(requires_new: true) do
        Project.connection.execute("INSERT INTO projects (user_id, name, kind, created_at, updated_at) VALUES (#{@user.id}, 'x', 'nope', now(), now())")
      end
    end
    assert_raises(ActiveRecord::NotNullViolation) do
      Project.transaction(requires_new: true) do
        Project.connection.execute("INSERT INTO projects (user_id, kind, created_at, updated_at) VALUES (#{@user.id}, 'game', now(), now())")
      end
    end
  end

  test "deleting a user deletes their projects, links and suggestions" do
    project = Project.create!(user: @other, name: "Mine")
    project.hackatime_links.create!(user_id: @other.id, hackatime_project: "mine", link_method: "manual")
    project.link_suggestions.create!(hackatime_project: "mine-2")
    keep = Project.create!(user: @user, name: "Not mine")

    @other.delete # no callbacks: only the database cascade is left to do the work

    assert_equal 0, Project.where(id: project.id).count
    assert_equal 0, HackatimeLink.where(project_id: project.id).count
    assert_equal 0, LinkSuggestion.where(project_id: project.id).count
    assert Project.exists?(keep.id)
  end
end
