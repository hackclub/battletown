require "test_helper"

# /admin/nps (flag nps): aggregate results for staff, comments without names, and the logged "show who wrote this".
class AdminNpsTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @admin = users(:onboarded)
    @teen = users(:new_user)
    @teen.update_columns(display_name: "Zed Writer-Person", onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
    Flipper.enable(:nps)
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

  def sign_in_admin
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @admin
  end

  def answer(user, score, comment = nil, at: Time.current, window: nil)
    NpsResponse.create!(user: user, score: score, comment: comment, answered_at: at, prompt_window_date: window || at.to_date)
  end

  # --- who can see it ---

  test "signed-out visitors and non-admins get a 404 on every NPS admin route" do
    comment = answer(@teen, 3, "private words")
    ENV["ADMIN_HCA_UIDS"] = "someone-else"
    [ nil, @admin, @teen ].each do |visitor|
      delete logout_path if visitor
      sign_in_as(visitor) if visitor
      get admin_nps_path
      assert_response :not_found
      post admin_nps_reveal_path(comment)
      assert_response :not_found
    end
    assert_equal 0, AdminAuditEvent.count, "a refused request logs nothing"
  end

  test "with the flag off even an admin gets a 404, and the dashboard shows no link" do
    sign_in_admin
    without_feature(:nps) do
      get admin_nps_path
      assert_response :not_found
      post admin_nps_reveal_path(answer(@teen, 3, "words"))
      assert_response :not_found
      get admin_root_path
      assert_select "a[href=?]", "/admin/nps", count: 0
    end
    assert_equal 0, AdminAuditEvent.count
  end

  test "an admin sees the dashboard link while the flag is on" do
    sign_in_admin
    get admin_root_path
    assert_select "a[href=?]", admin_nps_path, text: "NPS survey"
  end

  # --- the page ---

  test "an empty page says no answers and is orange admin UI" do
    sign_in_admin
    get admin_nps_path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only"
    assert_select "h1", "NPS survey"
    assert_select ".admin-nps__score", "No answers"
    assert_select ".empty", "No comments yet."
    assert_select "table.admin-table tbody tr", Nps::Stats::TREND_DAYS
  end

  test "it shows the aggregate NPS, the counts and the 14 day trend" do
    now = Time.current
    [ 10, 9, 9, 8, 7, 3 ].each_with_index { |score, i| answer(User.create!(hca_uid: "nps-#{i}-#{SecureRandom.hex(3)}"), score, at: now - i.hours) }
    sign_in_admin
    get admin_nps_path
    # 3 promoters, 2 passives, 1 detractor of 6: (3 - 1) / 6 = 33
    assert_select ".admin-nps__score", "+33"
    assert_select "dl.admin-stat" do
      assert_select "dd", text: "6"
      assert_select "dd", text: "3"
    end
    assert_select "table caption", /last|NPS by day/
  end

  test "comments are listed without who wrote them, escaped, newest first" do
    answer(@teen, 2, "older <script>alert(1)</script>", at: 2.days.ago)
    answer(users(:new_user), 9, nil, at: 1.day.ago, window: Date.current - 1) # no comment: not listed
    answer(@admin, 10, "newer words", at: 1.hour.ago)
    sign_in_admin
    get admin_nps_path
    assert_select ".admin-nps__comment", 2
    assert_select ".admin-nps__comment:first-child .admin-nps__text", "newer words"
    assert_not_includes response.body, "<script>alert(1)"
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_not_includes response.body, "Zed Writer-Person"
    assert_not_includes response.body, @teen.hca_uid
    assert_not_includes response.body, @teen.slack_id.to_s if @teen.slack_id.present?
    assert_select "form[action=?] button", admin_nps_reveal_path(NpsResponse.find_by(comment: "newer words")), text: "Show who wrote this"
    assert_equal 0, AdminAuditEvent.count, "just looking at the page logs nothing"
  end

  # --- show who wrote this ---

  test "the reveal shows the display name for that one comment and writes a log row with no content or name" do
    wanted = answer(@teen, 2, "I am confused about coins")
    other = answer(@admin, 8, "a different comment", at: 1.hour.ago, window: Date.current - 3)
    sign_in_admin
    assert_difference -> { AdminAuditEvent.count }, 1 do
      post admin_nps_reveal_path(wanted)
    end
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select ".admin-only"
    assert_select "strong", /Zed Writer-Person/
    assert_select ".admin-nps__text", "I am confused about coins"
    assert_not_includes response.body, "a different comment"
    assert_not_includes response.body, @teen.email.to_s if @teen.email.present?

    log = AdminAuditEvent.sole
    assert_equal [ @admin.id, "nps_comment_author_viewed", "NpsResponse", wanted.id ], [ log.actor_id, log.action, log.subject_type, log.subject_id ]
    dumped = log.attributes.values.join(" ")
    assert_no_match(/Zed|confused|coins/, dumped)
    assert_not_equal other.id, log.subject_id
  end

  test "every reveal is logged, including a repeat" do
    wanted = answer(@teen, 2, "words")
    sign_in_admin
    2.times { post admin_nps_reveal_path(wanted) }
    assert_equal 2, AdminAuditEvent.where(subject_id: wanted.id).count
  end

  test "revealing a missing row or one without a comment is a 404 and logs nothing" do
    sign_in_admin
    post admin_nps_reveal_path(999_999)
    assert_response :not_found
    post admin_nps_reveal_path(answer(@teen, 5))
    assert_response :not_found
    assert_equal 0, AdminAuditEvent.count
  end

  test "a person with no display name shows a plain note" do
    @teen.update_columns(display_name: nil)
    sign_in_admin
    post admin_nps_reveal_path(answer(@teen, 2, "words"))
    assert_select "strong", /No display name on file/
  end

  test "the reveal button needs the CSRF token" do
    wanted = answer(@teen, 2, "words")
    sign_in_admin
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    begin
      post admin_nps_reveal_path(wanted)
      assert_response :unprocessable_content
      assert_equal 0, AdminAuditEvent.count
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end
end
