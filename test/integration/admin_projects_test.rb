require "test_helper"
require_relative "../support/ships_test_support"

class AdminProjectsTest < ActionDispatch::IntegrationTest
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }

  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false

    @admin = users(:onboarded)
    @teen = users(:new_user)
    @teen.update_columns(display_name: "Casey Teen", email: "casey@example.test", slack_id: "U0CASEY", onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
    @project = make_project(@teen, name: "Cow Game")
    @project.update_columns(idea: "A game about cows.\nSecond line.", repo_url: "https://github.com/octo/space-farm", demo_url: "https://play.example.test/cows")
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_env.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_env
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def sign_in_admin(user = @admin)
    ENV["ADMIN_HCA_UIDS"] = user.hca_uid
    sign_in_as user
  end

  def more_projects(count, owner: @teen, **attrs)
    count.times.map do |index|
      Project.create!(user: User.create!(hca_uid: "ident!bulk-#{owner.id}-#{index}-#{SecureRandom.hex(3)}", display_name: "Bulk #{index}"), name: "Bulk #{index}", kind: "tool", **attrs)
    end
  end

  def queue_names = css_select("tbody tr th").map { |cell| cell.children.first.text.strip }

  def page_text = css_select("main").text.squish

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  # --- access ---

  ROUTES = [ [ :get, "/admin/projects" ], [ :get, "/admin/projects/%{id}" ], [ :post, "/admin/projects/%{id}/ok" ], [ :post, "/admin/projects/%{id}/flag" ],
             [ :post, "/admin/projects/%{id}/clear" ], [ :post, "/admin/projects/%{id}/note" ] ].freeze

  test "the project review routes are exactly the ones this test covers" do
    routes = Rails.application.routes.routes.select { |r| r.defaults[:controller] == "admin/projects" }
                  .map { |r| [ r.verb.downcase.to_sym, r.path.spec.to_s.sub("(.:format)", "").sub(":id", "%{id}") ] }
    assert_equal ROUTES.sort, routes.sort
  end

  test "signed-out visitors and non-admins get the plain 404 on every route and nothing changes" do
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    missing = (get("/definitely-not-a-page") && response.body)
    [ nil, @teen ].each do |visitor|
      sign_in_as(visitor) if visitor
      ROUTES.each do |verb, path|
        process verb, format(path, id: @project.id), params: { note: "x", details: "x", reason_preset: "Other" }
        assert_response :not_found, "#{verb} #{path} for #{visitor ? 'a teen' : 'a signed-out visitor'}"
        assert_equal missing, response.body
      end
    end
    assert_equal "unreviewed", @project.reload.review_status
    assert_equal 0, ProjectReview.count
  end

  test "an admin who is not staff any more is a 404 on the next request" do
    sign_in_admin
    get "/admin/projects"
    assert_response :success
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    get "/admin/projects"
    assert_response :not_found
  end

  test "unknown, malformed and out-of-range ids are a 404 for an admin" do
    sign_in_admin
    [ 0, 987_654_321, "99999999999999999999999", "abc", "#{@project.id}abc", "-1", "1.5" ].each do |id|
      get "/admin/projects/#{id}"
      assert_response :not_found, id.to_s
      post "/admin/projects/#{id}/ok"
      assert_response :not_found, id.to_s
    end
    assert_equal 0, ProjectReview.count
  end

  test "every write rejects a missing CSRF token (422) for an admin, and still 404s for everyone else" do
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    original = ActionController::Base.allow_forgery_protection
    begin
      post "/admin/projects/#{@project.id}/ok"
      assert_response :not_found # signed out
      sign_in_as @admin
      ActionController::Base.allow_forgery_protection = true
      %w[ok flag clear note].each do |action|
        post "/admin/projects/#{@project.id}/#{action}", params: { details: "x", note: "x" }
        assert_response :unprocessable_content, action
      end
      assert_equal 0, ProjectReview.count
      ActionController::Base.allow_forgery_protection = false
      delete logout_path
      sign_in_as @teen
      ActionController::Base.allow_forgery_protection = true
      post "/admin/projects/#{@project.id}/flag", params: { details: "x" }
      assert_response :not_found
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end

  test "responses are never cached" do
    sign_in_admin
    get "/admin/projects"
    assert_equal "no-store", response.headers["Cache-Control"]
    get "/admin/projects/#{@project.id}"
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  # --- the queue ---

  test "the queue shows the owner's display name and project facts but no email, Slack id or Hack Club Auth id" do
    code(@teen, D[9], HOUR * 2)
    submit_ship(@project)
    sign_in_admin
    get "/admin/projects"
    assert_response :success
    assert_select ".admin-only h1", "Project review"
    assert_select "tbody tr th", text: /Cow Game/
    assert_select "tbody td", text: "Casey Teen"
    assert_select "tbody td.num", text: "2 hours"
    assert_select "tbody td", text: "1 ship (1 waiting)"
    assert_select "tbody td", text: "Unreviewed"
    [ "casey@example.test", "U0CASEY", @teen.hca_uid, "done@example.test" ].each { |secret| assert_not_includes response.body, secret }
  end

  test "repo and demo links are plain https links that open in a new tab with noopener noreferrer nofollow" do
    sign_in_admin
    get "/admin/projects"
    assert_select "tbody a[href='https://github.com/octo/space-farm'][target=_blank][rel='noopener noreferrer nofollow']", text: "github.com/octo/space-farm"
    assert_select "tbody a[href='https://play.example.test/cows'][rel='noopener noreferrer nofollow']"
    get "/admin/projects/#{@project.id}"
    assert_select "dd a[href='https://github.com/octo/space-farm'][target=_blank][rel='noopener noreferrer nofollow']"
    assert_select "iframe, embed, object, img[src^='http']", 0
  end

  test "the queue shows each project's hours via its linked Hackatime projects and counts only linked, counted time" do
    code(@teen, D[8], HOUR)
    code(@teen, D[9], HOUR / 2)
    code(@teen, D[9], HOUR * 5, hackatime: "not-linked")
    HourEntry.create!(user: @teen, local_date: Date.new(2025, 12, 31), seconds: HOUR * 4, source: "manual", note: "t", hackatime_project: "space-farm", idempotency_key: "old") # before signing up
    make_project(@teen, name: "Website", hackatime: "website")
    code(@teen, D[9], HOUR, hackatime: "website")
    sign_in_admin
    get "/admin/projects", params: { sort: "hours" }
    assert_equal [ "Cow Game", "Website" ], queue_names
    assert_select "tbody tr:nth-child(1) td.num", text: "1.5 hours"
    assert_select "tbody tr:nth-child(2) td.num", text: "1 hour"
  end

  test "a project with no Hackatime link shows 0 hours" do
    @project.hackatime_links.destroy_all
    sign_in_admin
    get "/admin/projects"
    assert_select "tbody td.num", text: "0 hours"
  end

  test "an adjustment can bring a project's hours down but never below zero" do
    code(@teen, D[8], HOUR)
    HourEntry.create!(user: @teen, local_date: D[8], seconds: -HOUR * 3, source: "adjustment", note: "fix", hackatime_project: "space-farm", idempotency_key: "adj")
    sign_in_admin
    get "/admin/projects"
    assert_select "tbody td.num", text: "0 hours"
  end

  test "an owner without a display name is shown as No name" do
    @teen.update_columns(display_name: nil)
    sign_in_admin
    get "/admin/projects"
    assert_select "tbody td", text: "No name"
  end

  # filters, search, sort

  test "filters by review state with counts, and ignores unknown values" do
    flagged, okay = more_projects(2)
    flagged.update!(name: "Flagged one")
    okay.update!(name: "Okay one")
    Projects::Review.flag(project: flagged, reviewer: @admin, details: "odd")
    Projects::Review.ok(project: okay, reviewer: @admin)
    sign_in_admin

    get "/admin/projects"
    assert_select ".admin-filter", text: "All (3)"
    assert_select ".admin-filter", text: "Unreviewed (1)"
    assert_select ".admin-filter", text: "Flagged (1)"
    assert_select ".admin-filter", text: "Reviewed OK (1)"

    { "flagged" => [ "Flagged one" ], "ok" => [ "Okay one" ], "unreviewed" => [ "Cow Game" ] }.each do |value, names|
      get "/admin/projects", params: { review: value }
      assert_equal names, queue_names, value
      assert_select ".admin-filter--current"
    end
    get "/admin/projects", params: { review: "bogus" }
    assert_select "tbody tr", 3
    get "/admin/projects", params: { review: [ "flagged" ] }
    assert_select "tbody tr", 3
    get "/admin/projects", params: { review: { "a" => "b" } }
    assert_select "tbody tr", 3
  end

  test "filters by active or archived" do
    archived = more_projects(1).first
    archived.update!(name: "Old one")
    archived.archive!
    sign_in_admin
    get "/admin/projects", params: { status: "archived" }
    assert_equal [ "Old one" ], queue_names
    get "/admin/projects", params: { status: "active" }
    assert_not_includes queue_names.join, "Old one"
    get "/admin/projects", params: { status: "bogus" }
    assert_select "tbody tr", 2
  end

  test "filters by has shipped and by linked Hackatime" do
    shipped = @project
    code(@teen, D[9], HOUR)
    submit_ship(shipped)
    draft_only = make_project(@teen, name: "Draft only", hackatime: "draft-only")
    code(@teen, D[9], HOUR, hackatime: "draft-only")
    submit_ship(draft_only, submit: false)
    unlinked = make_project(@teen, name: "Unlinked", hackatime: nil)
    sign_in_admin

    get "/admin/projects", params: { shipped: "yes" }
    assert_equal [ "Cow Game" ], queue_names
    get "/admin/projects", params: { shipped: "no" }
    assert_equal [ "Draft only", "Unlinked" ], queue_names.sort
    get "/admin/projects", params: { linked: "no" }
    assert_equal [ "Unlinked" ], queue_names
    get "/admin/projects", params: { linked: "yes" }
    assert_select "tbody tr", 2
    get "/admin/projects", params: { linked: "yes", shipped: "no" }
    assert_equal [ "Draft only" ], queue_names
    assert unlinked
  end

  test "a draft ship does not count as shipped and is never listed" do
    draft_only = make_project(@teen, name: "Drafty", hackatime: "drafty")
    code(@teen, D[9], HOUR, hackatime: "drafty")
    submit_ship(draft_only, submit: false)
    sign_in_admin
    get "/admin/projects", params: { q: "Drafty" }
    assert_select "tbody td", text: "None"
  end

  test "searches the project name or repo link, ignoring case" do
    other = more_projects(1).first
    other.update_columns(name: "Pixel Quest", repo_url: "https://github.com/someone/pixel-quest")
    sign_in_admin
    { "cow" => [ "Cow Game" ], "COW" => [ "Cow Game" ], "pixel" => [ "Pixel Quest" ], "someone/pixel" => [ "Pixel Quest" ], "github.com/octo" => [ "Cow Game" ],
      "nothing-like-this" => [] }.each do |term, names|
      get "/admin/projects", params: { q: term }
      assert_equal names, queue_names, term
    end
  end

  test "weird search input is treated as plain text" do
    tricky = more_projects(1).first
    tricky.update_columns(name: "100% sure_thing")
    sign_in_admin
    [ "' OR 1=1 --", "\"; DROP TABLE projects; --", "%", "_", "\\", "a" * 5000, "Ünïcödé 日本語 🦦", "<script>alert(1)</script>", "\u0000", "  ", "%00" ].each do |term|
      get "/admin/projects", params: { q: term }
      assert_response :success, term[0, 20]
    end
    assert_equal 2, Project.count
    get "/admin/projects", params: { q: "100%" }
    assert_equal [ "100% sure_thing" ], queue_names
    get "/admin/projects", params: { q: "%" }
    assert_equal [ "100% sure_thing" ], queue_names # a literal percent sign, not a wildcard
    get "/admin/projects", params: { q: "sure_thing" }
    assert_select "tbody tr", 1
    get "/admin/projects", params: { q: "sure-thing" } # an underscore is not a wildcard either
    assert_select "tbody tr", 0
    get "/admin/projects", params: { q: [ "cow" ] }
    assert_select "tbody tr", 2
  end

  test "a very long search term is cut to 100 characters and shown back cut" do
    sign_in_admin
    get "/admin/projects", params: { q: "x" * 5000 }
    assert_select "input[name=q][value=?]", "x" * 100
  end

  test "the search box is escaped when shown back" do
    sign_in_admin
    get "/admin/projects", params: { q: "\"><script>alert(1)</script>" }
    assert_not_includes response.body, "<script>alert(1)"
    assert_select "input[name=q]"
  end

  test "invalid UTF-8 in the search is not a server error" do
    sign_in_admin
    get "/admin/projects?q=%FF%FEcow"
    assert_includes [ 200, 400 ], response.status
  end

  test "sorts newest first by default, oldest first, or by most hours" do
    old = more_projects(1).first
    old.update_columns(name: "Ancient", created_at: 3.days.ago)
    busy = make_project(@teen, name: "Busy", hackatime: "busy")
    busy.update_columns(created_at: 2.days.ago)
    code(@teen, D[9], HOUR * 3, hackatime: "busy")
    code(@teen, D[9], HOUR)
    sign_in_admin
    order = ->(params) { get("/admin/projects", params: params) && queue_names }
    assert_equal [ "Cow Game", "Busy", "Ancient" ], order.call({})
    assert_equal [ "Ancient", "Busy", "Cow Game" ], order.call(sort: "oldest")
    assert_equal [ "Busy", "Cow Game", "Ancient" ], order.call(sort: "hours")
    assert_equal [ "Cow Game", "Busy", "Ancient" ], order.call(sort: "DROP TABLE")
  end

  test "paginates 50 a page with boundaries, and an out-of-range or odd page falls back safely" do
    more_projects(Admin::ProjectsController::PER_PAGE) # 51 in all
    sign_in_admin
    get "/admin/projects"
    assert_select "tbody tr", 50
    assert_select ".admin-pager__where", text: /Page 1 of 2/
    assert_select ".admin-pager a[rel=next]"
    assert_select ".admin-pager a[rel=prev]", 0
    get "/admin/projects", params: { page: 2 }
    assert_select "tbody tr", 1
    assert_select ".admin-pager a[rel=prev]"
    assert_select ".admin-pager a[rel=next]", 0
    [ 3, 99, "99999999999999999999", 0, -1, "abc", "2abc", [ 2 ] ].each do |page|
      get "/admin/projects", params: { page: page }
      assert_response :success, page.inspect
    end
    get "/admin/projects", params: { page: 99 }
    assert_select ".admin-pager__where", text: /Page 2 of 2/
    get "/admin/projects", params: { page: 0 }
    assert_select ".admin-pager__where", text: /Page 1 of 2/
    # exactly 50 is one page
    Project.where(id: Project.order(:id).last.id).destroy_all
    get "/admin/projects"
    assert_select "tbody tr", 50
    assert_select ".admin-pager", 0
  end

  test "pagination links keep the filters" do
    more_projects(Admin::ProjectsController::PER_PAGE)
    sign_in_admin
    get "/admin/projects", params: { review: "unreviewed", sort: "oldest", q: "b" }
    assert_select ".admin-pager a[rel=next][href*='review=unreviewed'][href*='sort=oldest'][href*='q=b']"
  end

  test "an empty result says so" do
    sign_in_admin
    get "/admin/projects", params: { q: "zzzzzz" }
    assert_select ".alert", text: /No projects match/
  end

  test "the queue has a constant number of queries whether there are 5 or 50 projects" do
    sign_in_admin
    more_projects(4)
    [ @project, *Project.where.not(id: @project.id) ].each_with_index do |project, index|
      Projects::Review.flag(project: project, reviewer: @admin, details: "x") if index.odd? && project.user_id != @admin.id
    end
    get "/admin/projects"
    five = count_queries { get "/admin/projects" }
    more_projects(45).each_with_index do |project, index|
      owner = project.user
      HackatimeLink.create!(user: owner, project: project, hackatime_project: "bulk-#{index}", link_method: "manual")
      code(owner, D[9], HOUR, hackatime: "bulk-#{index}")
      Ship.create!(user: owner, project: project, status: "approved", description: "d", repo_url: REPO, coded_seconds: HOUR, approved_seconds: HOUR, reviewed_at: Time.current,
                   window_start_date: D[9], window_end_date: D[9], daily_seconds: { "2026-11-09" => HOUR }, submitted_at: Time.current) if index.even?
    end
    assert_equal 50, Project.count
    fifty = count_queries { get "/admin/projects" }
    assert_response :success
    assert_select "tbody tr", 50
    assert_operator fifty, :<=, five, "the queue ran #{fifty} queries for 50 projects but #{five} for 5"
    assert_operator fifty, :<=, 12
  end

  test "the detail page has a constant number of queries however many ships and reviews there are" do
    sign_in_admin
    other = User.create!(hca_uid: "ident!rev-many", display_name: "Rev Many")
    Projects::Review.ok(project: @project, reviewer: other)
    Ship.create!(user: @teen, project: @project, status: "withdrawn", description: "d", repo_url: REPO, coded_seconds: HOUR, window_start_date: D[1], window_end_date: D[1],
                 daily_seconds: { "2026-11-01" => HOUR }, submitted_at: Time.current)
    get "/admin/projects/#{@project.id}"
    one = count_queries { get "/admin/projects/#{@project.id}" }
    10.times { |i| Projects::Review.add_note(project: @project, reviewer: other, note: "n#{i}") }
    (2..6).each do |day|
      Ship.create!(user: @teen, project: @project, status: "withdrawn", description: "d", repo_url: REPO, coded_seconds: HOUR, window_start_date: D[day], window_end_date: D[day],
                   daily_seconds: { "2026-11-0#{day}" => HOUR }, submitted_at: Time.current)
    end
    many = count_queries { get "/admin/projects/#{@project.id}" }
    assert_equal one, many
  end

  # --- the detail page ---

  test "the detail page shows the idea as escaped plain text with line breaks kept, hours by week, ships and review history" do
    @project.update_columns(idea: "Line one <b>bold</b>\nLine two <img src=x onerror=alert(1)>")
    code(@teen, D[5], HOUR)
    code(@teen, D[9], HOUR * 2)
    ship = submit_ship(@project)
    Projects::Review.ok(project: @project, reviewer: @admin, note: "Nice")
    sign_in_admin
    get "/admin/projects/#{@project.id}"
    assert_response :success
    assert_select "h1", "Project: Cow Game"
    assert_equal "Line one <b>bold</b>\nLine two <img src=x onerror=alert(1)>", css_select("p.admin-text").first.text
    assert_select "p.admin-text b, p.admin-text img", 0
    assert_not_includes response.body, "<img src=x"
    assert_select ".chip-name", "space-farm"
    assert_select "caption", text: /Hours coded by week/
    assert_select "tbody tr th", text: /Oct 30, 2026/
    assert_select "tbody tr th", text: /Nov 6, 2026/
    assert_select "tbody td", text: "1 hour"
    assert_select "tbody td", text: "2 hours"
    assert_select "a[href=?]", "/admin/ships/#{ship.id}", text: "Open"
    assert_select "caption", text: /Review history/
    assert_select "td", text: "Nice"
    assert_select "td", text: @admin.display_name
    assert_select "dd", text: "Casey Teen"
    [ "casey@example.test", "U0CASEY", @teen.hca_uid ].each { |secret| assert_not_includes response.body, secret }
  end

  test "names and ideas with HTML and javascript: text are escaped; stored links can only ever be https" do
    @project.update_columns(name: "<script>alert('n')</script>", idea: "javascript:alert(1) <a href='javascript:alert(2)'>x</a>")
    @teen.update_columns(display_name: "<img src=x onerror=alert(3)>")
    sign_in_admin
    [ "/admin/projects", "/admin/projects/#{@project.id}" ].each do |path|
      get path
      assert_response :success
      assert_not_includes response.body, "<script>alert('n')"
      assert_not_includes response.body, "<img src=x onerror"
      assert_select "a[href^='javascript:']", 0
      assert_select "main a[href]:not([href^='/']):not([href^='https://'])", 0
    end
    assert_raises(ActiveRecord::StatementInvalid) { @project.update_columns(demo_url: "javascript:alert(1)") }
    assert_raises(ActiveRecord::StatementInvalid) { @project.update_columns(demo_url: "http://insecure.example.test") }
  end

  test "an external link helper refuses anything but https" do
    helper = ApplicationController.helpers
    assert_nil helper.admin_external_link("javascript:alert(1)")
    assert_nil helper.admin_external_link("http://example.test")
    assert_nil helper.admin_external_link("https://x y")
    assert_nil helper.admin_external_link(nil)
    assert_includes helper.admin_external_link("https://example.test/a?b=\"c\""), "rel=\"noopener noreferrer nofollow\""
    assert_not_includes helper.admin_external_link("https://example.test/a?b=\"c\""), "b=\"c\""
  end

  test "the owner links to the staff user page only when that route exists" do
    sign_in_admin
    get "/admin/projects/#{@project.id}"
    if Rails.application.routes.url_helpers.respond_to?(:admin_user_path)
      assert_select "dd a[href=?]", "/admin/users/#{@teen.id}", text: "Casey Teen"
    else
      assert_select "dd a", text: "Casey Teen", count: 0
      assert_select "dd", text: "Casey Teen"
    end
  end

  test "the detail page lists every ship but never a draft, and projects without ships say so" do
    sign_in_admin
    get "/admin/projects/#{@project.id}"
    assert_select "p", text: "No ships submitted yet."
    code(@teen, D[9], HOUR)
    submit_ship(@project, submit: false)
    get "/admin/projects/#{@project.id}"
    assert_select "p", text: "No ships submitted yet."
  end

  test "a project with no idea, no repo and no Hackatime link still renders" do
    bare = Project.create!(user: @teen, name: "Bare", kind: "undecided")
    sign_in_admin
    get "/admin/projects/#{bare.id}"
    assert_response :success
    assert_select "p.admin-text", text: "No idea written."
    assert_select "dd", text: "None linked now"
    assert_select "p", text: /No coded time/
  end

  test "every review, flag, clear and note writes an audit event that shows on the audit page, and a refused one does not" do
    sign_in_admin
    post "/admin/projects/#{@project.id}/ok"
    post "/admin/projects/#{@project.id}/flag", params: { details: "odd" }
    post "/admin/projects/#{@project.id}/note", params: { note: "n" }
    post "/admin/projects/#{@project.id}/clear"
    post "/admin/projects/#{@project.id}/flag" # refused: no reason
    post "/admin/projects/#{@project.id}/clear" # refused: not flagged
    assert_equal %w[project_reviewed project_flagged project_note_added project_cleared], AdminAuditEvent.order(:id).pluck(:action)
    get "/admin/audit"
    assert_response :success
    assert_select "th", text: "Project flagged"
    assert_select "td", text: "Project ##{@project.id}", minimum: 4
    assert_not_includes response.body, "Casey Teen"
  end

  test "viewing the queue or a project writes no audit event and no review" do
    sign_in_admin
    assert_no_difference -> { ProjectReview.count } do
      assert_no_difference -> { AdminAuditEvent.count } do
        get "/admin/projects"
        get "/admin/projects/#{@project.id}"
      end
    end
  end

  # --- the review flow ---

  test "mark OK with and without a note" do
    sign_in_admin
    post "/admin/projects/#{@project.id}/ok"
    assert_redirected_to "/admin/projects/#{@project.id}"
    follow_redirect!
    assert_select ".flash", text: /Marked OK/
    assert_select ".badge", text: "Reviewed OK"
    post "/admin/projects/#{@project.id}/ok", params: { note: "Seems real" }
    assert_equal [ "Seems real", nil ], @project.project_reviews.map(&:note)
    assert_equal "ok", @project.reload.review_status
  end

  test "flag with a preset, with details, and with both; the history shows it newest first" do
    sign_in_admin
    post "/admin/projects/#{@project.id}/flag", params: { reason_preset: "Needs a safety check" }
    assert_redirected_to "/admin/projects/#{@project.id}"
    post "/admin/projects/#{@project.id}/flag", params: { reason_preset: "Links don't work", details: "Demo is a 404" }
    assert_equal [ "Links don't work: Demo is a 404", "Needs a safety check" ], @project.project_reviews.map(&:note)
    get "/admin/projects/#{@project.id}"
    assert_select ".badge", text: "Flagged", minimum: 2
    assert_equal [ "Links don't work: Demo is a 404", "Needs a safety check" ], css_select("tbody td.admin-text").map { |cell| cell.text.strip }
  end

  test "flag without a reason shows a friendly error, keeps the typed text and changes nothing" do
    sign_in_admin
    post "/admin/projects/#{@project.id}/flag", params: { reason_preset: "Other", details: "" }
    assert_response :unprocessable_content
    assert_select ".alert--danger", text: /Say a few words about why/
    post "/admin/projects/#{@project.id}/flag", params: { details: "x" * 501 }
    assert_response :unprocessable_content
    assert_select "textarea[name=details]", text: "x" * 501
    assert_equal 0, ProjectReview.count
    assert_equal "unreviewed", @project.reload.review_status
  end

  test "clear flag, add a note, and the errors for steps that no longer make sense" do
    sign_in_admin
    post "/admin/projects/#{@project.id}/clear"
    assert_response :unprocessable_content
    assert_select ".alert--danger", text: /not flagged/
    post "/admin/projects/#{@project.id}/note", params: { note: "too early" }
    assert_response :unprocessable_content
    post "/admin/projects/#{@project.id}/flag", params: { details: "odd" }
    post "/admin/projects/#{@project.id}/note", params: { note: "Asked them" }
    assert_redirected_to "/admin/projects/#{@project.id}"
    assert_equal "flagged", @project.reload.review_status
    post "/admin/projects/#{@project.id}/clear", params: { note: "All good" }
    assert_redirected_to "/admin/projects/#{@project.id}"
    assert_equal "ok", @project.reload.review_status
    get "/admin/projects/#{@project.id}"
    assert_select "td .badge", text: "Flag cleared"
  end

  test "the page offers Clear flag only while flagged, and Mark OK only while not" do
    sign_in_admin
    get "/admin/projects/#{@project.id}"
    assert_select "input[type=submit][value='Mark OK']"
    assert_select "input[type=submit][value='Clear flag']", 0
    assert_select "input[type=submit][value='Add note']", 0
    Projects::Review.flag(project: @project, reviewer: @admin, details: "odd")
    get "/admin/projects/#{@project.id}"
    assert_select "input[type=submit][value='Clear flag']"
    assert_select "input[type=submit][value='Mark OK']", 0
    assert_select "input[type=submit][value='Add note']"
    assert_equal [ "Pick one (or write your own below)" ] + Projects::Review::REASONS, css_select("select[name=reason_preset] option").map { |option| option.text.strip }
  end

  test "staff cannot review their own project: friendly error, no forms, nothing written" do
    mine = Project.create!(user: @admin, name: "Staff project", kind: "tool")
    sign_in_admin
    get "/admin/projects/#{mine.id}"
    assert_response :success
    assert_select ".alert", text: /your own project/
    assert_select "form[action*='/flag']", 0
    %w[ok flag clear note].each do |action|
      post "/admin/projects/#{mine.id}/#{action}", params: { details: "x", note: "x" }
      assert_response :unprocessable_content, action
      assert_select ".alert--danger", text: /someone else on the team/
    end
    assert_equal 0, ProjectReview.count
  end

  test "reviewing never changes the teen's hours, coins, ships or project" do
    code(@teen, D[9], HOUR)
    ship = submit_ship(@project)
    teen_before = @teen.reload.attributes
    project_before = @project.reload.attributes.except("review_status", "reviewed_at")
    counts = -> { [ HourEntry.count, CoinTransaction.count, Order.count, Notification.count, Ship.count, ship.reload.attributes ] }
    before = counts.call
    sign_in_admin
    post "/admin/projects/#{@project.id}/flag", params: { reason_preset: "Inappropriate content" }
    post "/admin/projects/#{@project.id}/clear"
    assert_equal before, counts.call
    assert_equal teen_before, @teen.reload.attributes
    assert_equal project_before, @project.reload.attributes.except("review_status", "reviewed_at")
    assert_equal "submitted", ship.reload.status
  end

  test "a flagged project can still be shipped, edited and deleted by the teen, who never sees the review" do
    Projects::Review.flag(project: @project, reviewer: @admin, preset: "Inappropriate content", details: "SECRETREASON")
    @teen.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
    delete logout_path
    sign_in_as @teen
    code(@teen, D[9], HOUR)
    [ "/projects", "/projects/#{@project.id}/edit", "/dashboard", "/ships" ].each do |path|
      get path
      assert_response :success, path
      %w[SECRETREASON Flagged flagged Inappropriate].each { |word| assert_not_includes response.body, word, "#{path} shows #{word}" }
    end
    assert_nothing_raised { submit_ship(@project) }
    patch "/projects/#{@project.id}", params: { project: { name: "Renamed", review_status: "ok" } }
    assert_equal "Renamed", @project.reload.name
    assert_equal "flagged", @project.review_status, "the teen cannot set the review state through the form"
  end

  test "a teen can delete a reviewed project and its reviews go with it" do
    Projects::Review.flag(project: @project, reviewer: @admin, details: "x")
    other = make_project(@teen, name: "Second", hackatime: "second")
    other.make_active!
    sign_in_as @teen
    assert_difference -> { ProjectReview.count }, -1 do
      delete "/projects/#{@project.id}"
    end
    assert_not Project.exists?(@project.id)
  end

  # --- the warning chips and the dashboard ---

  test "the ship review page warns staff when the project is flagged and says nothing otherwise" do
    code(@teen, D[9], HOUR)
    ship = submit_ship(@project)
    sign_in_admin
    get "/admin/ships/#{ship.id}"
    assert_select ".admin-flagged-chip", 0
    Projects::Review.flag(project: @project, reviewer: @admin, preset: "Needs a safety check")
    get "/admin/ships/#{ship.id}"
    assert_select ".admin-flagged-chip .badge", text: "Flagged project"
    assert_select ".admin-flagged-chip a[href=?]", "/admin/projects/#{@project.id}"
    assert_not_includes response.body, "safety check", "the reason stays on the project page"
    Projects::Review.clear(project: @project, reviewer: @admin)
    get "/admin/ships/#{ship.id}"
    assert_select ".admin-flagged-chip", 0
  end

  test "flagging does not stop staff approving the ship" do
    code(@teen, D[9], HOUR)
    @teen.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: D[1])
    ship = submit_ship(@project)
    Projects::Review.flag(project: @project, reviewer: @admin, details: "odd")
    sign_in_admin
    patch "/admin/ships/#{ship.id}/approve"
    assert_equal "approved", ship.reload.status
  end

  test "the dashboard shows how many projects wait for review and how many are flagged, as a link to the queue" do
    others = more_projects(3)
    Projects::Review.flag(project: others[0], reviewer: @admin, details: "x")
    Projects::Review.ok(project: others[1], reviewer: @admin)
    sign_in_admin
    get "/admin"
    assert_select ".admin-only a[href='/admin/projects']", "Project review"
    assert_select ".admin-link .badge", text: "2 projects waiting for review"
    assert_select ".admin-link .badge", text: "1 flagged"
    assert_select "h2", text: "Review"
    assert_not_includes response.body, "Bulk 0"
  end

  test "the dashboard singular and zero cases" do
    Project.where.not(id: @project.id).destroy_all
    sign_in_admin
    get "/admin"
    assert_select ".admin-link .badge", text: "1 project waiting for review"
    assert_select ".admin-link .badge", text: "0 flagged"
    Projects::Review.ok(project: @project, reviewer: @admin)
    get "/admin"
    assert_select ".admin-link .badge", text: "0 projects waiting for review"
  end

  test "the dashboard counts are one aggregate query, not one per project" do
    more_projects(20)
    sign_in_admin
    get "/admin"
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('FROM "projects"') }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/admin" }
    assert_operator queries.size, :<=, 1
  end

  # --- rate limit ---

  test "review writes are throttled per address" do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    sign_in_admin
    headers = { "REMOTE_ADDR" => "203.0.113.50" }
    30.times { post "/admin/projects/#{@project.id}/note", params: { note: "x" }, headers: headers }
    post "/admin/projects/#{@project.id}/note", params: { note: "x" }, headers: headers
    assert_response :too_many_requests
    get "/admin/projects", headers: headers
    assert_response :success, "reading the queue is not throttled by the review limit"
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store.clear
  end

  test "search terms and flag details are not written to the request log" do
    sign_in_admin
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    original = Rails.logger
    ActiveSupport::LogSubscriber.logger = logger
    ActionController::Base.logger = logger
    begin
      get "/admin/projects", params: { q: "findme-secret-term" }
      post "/admin/projects/#{@project.id}/flag", params: { details: "details-secret-text", reason_preset: "Other" }
    ensure
      ActionController::Base.logger = original
      ActiveSupport::LogSubscriber.logger = original
    end
    assert_includes io.string, "Processing by Admin::ProjectsController#index", "the log was captured"
    assert_includes io.string, "[FILTERED]"
    assert_not_includes io.string, "findme-secret-term"
    assert_not_includes io.string, "details-secret-text"
  end
end
