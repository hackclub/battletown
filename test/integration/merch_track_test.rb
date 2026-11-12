require "test_helper"
require_relative "../support/merch_helper"

# The weekly merch track pages, with the flag on and off. The clock is fixed inside each test (travel_to).
class MerchTrackTest < ActionDispatch::IntegrationTest
  include MerchHelper

  MID_WEEK = Time.utc(2026, 11, 16, 12)

  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @boss = make_boss
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1), signed_up_on: Date.new(2026, 11, 1))
    @admin = users(:new_user)
    @admin.update_columns(hca_uid: "ident!merch-admin")
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

  def as_admin
    ENV["ADMIN_HCA_UIDS"] = @admin.hca_uid
    sign_in_as @admin
  end

  def earn_week(user = @user, count: 5) = goal_days(user, count)

  # --- flag off: nothing exists ---

  test "with the flag off every merch route is a 404 and nothing is created" do
    earn_week
    verified!(@user)
    approved_ship!(@user)
    travel_to(AFTER_WEEK) do
      sign_in_as @user
      get "/merch"
      assert_response :not_found
      post "/merch/weeks/#{@boss.id}/claim"
      assert_response :not_found
      assert_equal 0, MerchClaim.count

      as_admin
      get "/admin/merch"
      assert_response :not_found
      patch "/admin/merch/1/fulfill"
      assert_response :not_found
    end
  end

  test "with the flag off the dashboard and the admin dashboard show nothing about the track" do
    earn_week
    travel_to(AFTER_WEEK) do
      sign_in_as @user
      get dashboard_path
      assert_response :success
      assert_no_match(/reward track|merch/i, css_select("main").to_s)

      as_admin
      get admin_root_path
      assert_response :success
      assert_no_match(/merch/i, css_select("main").to_s)
    end
  end

  test "routes recognise merch only while the flag is on" do
    without_feature(:merch_track) do
      assert_equal({ controller: "referrals", action: "show", ref: "merch" }, Rails.application.routes.recognize_path("/merch"), "falls through to the referral catch-all, which 404s")
      assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/admin/merch") }
    end
    with_feature(:merch_track) do
      assert_equal({ controller: "merch", action: "index" }, Rails.application.routes.recognize_path("/merch"))
      assert_equal({ controller: "admin/merch_claims", action: "index" }, Rails.application.routes.recognize_path("/admin/merch"))
    end
  end

  # --- flag on: access ---

  test "signed-out visitors are sent home and cannot claim" do
    with_feature(:merch_track) do
      get "/merch"
      assert_redirected_to root_path
      post "/merch/weeks/#{@boss.id}/claim"
      assert_redirected_to root_path
      assert_equal 0, MerchClaim.count
    end
  end

  test "people who have not finished onboarding are sent to onboarding" do
    with_feature(:merch_track) do
      sign_in_as users(:new_user)
      get "/merch"
      assert_redirected_to onboarding_path
      post "/merch/weeks/#{@boss.id}/claim"
      assert_redirected_to onboarding_path
    end
  end

  test "a claim needs the CSRF token" do
    with_feature(:merch_track) do
      earn_week
      verified!(@user)
      approved_ship!(@user)
      sign_in_as @user
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      travel_to(AFTER_WEEK) { post "/merch/weeks/#{@boss.id}/claim" }
      assert_response :unprocessable_entity
      assert_equal 0, MerchClaim.count
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end

  test "the claim route needs a numeric boss id and an unknown boss is a 404" do
    with_feature(:merch_track) do
      sign_in_as @user
      post "/merch/weeks/abc/claim"
      assert_response :not_found
      post "/merch/weeks/#{Boss.maximum(:id) + 100}/claim"
      assert_response :not_found
    end
  end

  # --- flag on: the dashboard card ---

  test "mid-week the dashboard card shows seven dots with text, the count and the item, and no claim button yet" do
    with_feature(:merch_track) do
      earn_week(count: 3)
      travel_to(MID_WEEK) do
        sign_in_as @user
        get dashboard_path
        assert_response :success
        assert_select "section.merch-card h2", "This week's reward track"
        assert_select ".merch-card .merch-day", 7
        assert_select ".merch-card .merch-day--met", 3
        assert_select ".merch-card .merch-day--pending.is-today", 1
        assert_select ".merch-card .merch-day--future", 3
        assert_select ".merch-card .merch-day .visually-hidden", text: /Friday 13 November: goal met/
        assert_select ".merch-card .merch-day .visually-hidden", text: /Monday 16 November \(today\): still counting/
        assert_select ".merch-card .merch-count strong", "3 of 5 days"
        assert_select ".merch-card .merch-item strong", "Week 1 sticker"
        assert_select ".merch-card .merch-message", /2 more goal days to go, with 4 days left this week/
        assert_select ".merch-card form", 0
      end
    end
  end

  test "an earned reward for an unverified person shows the locked note with the verify link, and no button" do
    with_feature(:merch_track) do
      earn_week
      travel_to(AFTER_WEEK) do
        sign_in_as @user
        get dashboard_path
        assert_select ".merch-card .merch-count strong", "5 of 5 days"
        assert_select ".merch-card #merch-verify-note", /Rewards unlock when you verify your identity with Hack Club/
        assert_select ".merch-card #merch-verify-note a[href='https://auth.hackclub.com']", 1
        assert_select ".merch-card form", 0
      end
    end
  end

  test "an earned reward with no approved ship says to ship, and shows no button" do
    with_feature(:merch_track) do
      earn_week
      verified!(@user)
      travel_to(AFTER_WEEK) do
        sign_in_as @user
        get dashboard_path
        assert_select ".merch-card .merch-message", /Ship a project and get it approved/
        assert_select ".merch-card form", 0
      end
    end
  end

  test "a short week says next week is a fresh start" do
    with_feature(:merch_track) do
      earn_week(count: 2)
      (WEEK_START + 2..WEEK_END).each { |date| goal_day(@user, date, met: false) }
      travel_to(AFTER_WEEK) do
        sign_in_as @user
        get dashboard_path
        assert_select ".merch-card .merch-message", "Next week is a fresh start."
        assert_no_match(/missed it/i, response.body)
      end
    end
  end

  test "claiming from the dashboard makes one claim, and a second press is a friendly no-op" do
    with_feature(:merch_track) do
      earn_week
      verified!(@user)
      approved_ship!(@user)
      travel_to(AFTER_WEEK) do
        sign_in_as @user
        get dashboard_path
        assert_select ".merch-card form[action^='#{merch_claim_path(boss_id: @boss.id)}'] button", /Claim this reward/
        post merch_claim_path(boss_id: @boss.id, from: "dashboard")
        assert_redirected_to dashboard_path
        follow_redirect!
        assert_select ".flash", /Claimed: Week 1 sticker. The team will message you on Slack to arrange delivery./
        assert_select ".merch-card .merch-message", /Claimed. The team will message you on Slack/
        assert_select ".merch-card form", 0

        post merch_claim_path(boss_id: @boss.id, from: "dashboard")
        follow_redirect!
        assert_select ".flash", /already claimed/
        assert_equal 1, MerchClaim.where(user_id: @user.id).count
      end
    end
  end

  test "a refused claim goes back with the reason and creates nothing" do
    with_feature(:merch_track) do
      earn_week
      travel_to(AFTER_WEEK) do
        sign_in_as @user
        post merch_claim_path(boss_id: @boss.id)
        assert_redirected_to merch_path
        follow_redirect!
        assert_select ".flash--alert", /verify your identity with Hack Club/
        assert_equal 0, MerchClaim.count
      end
    end
  end

  # --- flag on: the track page ---

  test "the track page lists all four weeks and the person's status for each" do
    with_feature(:merch_track) do
      earn_week
      verified!(@user)
      approved_ship!(@user)
      make_boss(starts_on: WEEK_START + 7)
      travel_to(AFTER_WEEK) do
        sign_in_as @user
        get merch_path
        assert_response :success
        assert_select "h1", "The reward track"
        assert_select ".merch-week", 4
        assert_select "#merch-week-1 h2", "Week 1: Week 1 sticker"
        assert_select "#merch-week-1 .badge", "Ready to claim"
        assert_select "#merch-week-1 form button", /Claim this reward/
        assert_select "#merch-week-2 .badge", "In progress"
        assert_select "#merch-week-3 .badge", "Coming up"
        assert_select "#merch-week-4 .badge", "Coming up"
        assert_select "#merch-week-3 .merch-message", /starts when the next boss arrives/
        assert_select "title", "Reward track - BattleTown"

        post merch_claim_path(boss_id: @boss.id)
        assert_redirected_to merch_path
        follow_redirect!
        assert_select "#merch-week-1 .badge", "Claimed"
      end
    end
  end

  test "the dashboard card points at earlier weeks that are still waiting" do
    with_feature(:merch_track) do
      earn_week
      second = make_boss(starts_on: WEEK_START + 7)
      travel_to(second.starts_on.in_time_zone("UTC") + 12.hours) do
        sign_in_as @user
        get dashboard_path
        assert_select ".merch-card .merch-note", "1 reward is waiting from earlier weeks."
        assert_select ".merch-card .merch-item strong", "Week 2 reward"
      end
    end
  end

  test "nothing about another person leaks: the page shows only the signed-in person's claims and no names" do
    with_feature(:merch_track) do
      other = claimant
      other.update_columns(display_name: "Quentin Zed", slack_id: "U0OTHER999")
      travel_to(AFTER_WEEK) { MerchTrack::Claim.call(user: other, boss: @boss, now: AFTER_WEEK) }
      earn_week
      travel_to(AFTER_WEEK) do
        sign_in_as @user
        get merch_path
        assert_response :success
        assert_select "#merch-week-1 .badge", "Locked for now"
        assert_no_match(/Quentin|U0OTHER999/, response.body)
        get dashboard_path
        assert_no_match(/Quentin|U0OTHER999/, response.body)
      end
    end
  end

  # --- flag on: staff ---

  test "non-admins get a 404 on the staff queue and cannot fulfil or cancel" do
    with_feature(:merch_track) do
      claim = claim_for(@user)
      get "/admin/merch"
      assert_response :not_found
      sign_in_as @user
      get "/admin/merch"
      assert_response :not_found
      patch "/admin/merch/#{claim.id}/fulfill"
      assert_response :not_found
      patch "/admin/merch/#{claim.id}/cancel"
      assert_response :not_found
      assert_predicate claim.reload, :requested?
    end
  end

  test "an admin sees the queue in an admin tool with name, Slack id and verification, and can fulfil and cancel" do
    with_feature(:merch_track) do
      @user.update_columns(slack_id: "U0MERCH123")
      waiting = claim_for(@user)
      cancelled = claim_for(claimant, boss: make_boss(starts_on: WEEK_START + 7))
      as_admin

      get "/admin/merch"
      assert_response :success
      assert_select ".admin-only"
      assert_select "#requested-count", "2"
      assert_select "#merch-claim-#{waiting.id}", /Veteran/
      assert_select "#merch-claim-#{waiting.id}", /U0MERCH123/
      assert_select "#merch-claim-#{waiting.id}", /Identity: verified/

      patch "/admin/merch/#{waiting.id}/fulfill"
      assert_redirected_to "/admin/merch"
      assert_predicate waiting.reload, :fulfilled?
      patch "/admin/merch/#{cancelled.id}/cancel"
      assert_predicate cancelled.reload, :cancelled?

      get "/admin/merch", params: { status: "fulfilled" }
      assert_select "#merch-claim-#{waiting.id}"
      assert_select "#merch-claim-#{cancelled.id}", 0
      patch "/admin/merch/#{cancelled.id}/fulfill"
      follow_redirect!
      assert_select ".flash--alert", /cancelled claim can't be fulfilled/
    end
  end

  test "the admin dashboard links to the queue while the flag is on" do
    with_feature(:merch_track) do
      claim_for(@user)
      as_admin
      get admin_root_path
      assert_select "a[href='/admin/merch']", "Merch claims"
      assert_select ".admin-link", /1 requested/
    end
  end

  private

  def claim_for(user, boss: @boss)
    verified!(user)
    MerchClaim.create!(user: user, boss: boss, item_key: "week_1_sticker", item_name: "Week 1 sticker", claimed_at: Time.utc(2026, 11, 20))
  end
end
