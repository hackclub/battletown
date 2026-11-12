require "test_helper"
require_relative "../support/shop_helper"
require_relative "../support/ships_test_support"

# The eligibility gate on spending (Flipper flag `eligibility_gate`): three states (unverified, verified but not
# eligible, verified and eligible) plus a stale verification, on every page that talks about spending, and the flag
# off meaning exactly what it meant before. Sign-in goes through OmniAuth test mode with real claims.
class EligibilityGateTest < ActionDispatch::IntegrationTest
  include ShopTestHelper
  include ShipsTestSupport

  NOT_ELIGIBLE = "Prizes are only available to people who qualify for Hack Club YSWS programs. Your account does not qualify yet.".freeze
  HELP = "Questions? Ask in Slack.".freeze
  RECHECK = "Sign in again to refresh your verification.".freeze
  D = ->(day) { Date.new(2026, 11, day) }
  HOURS_NOW = Time.utc(2026, 11, 10, 12)

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  # Sign in with these Hack Club claims (what the sign-in stores), then optionally age the stored check.
  def sign_in_as(user, status: "verified", eligible: true, checked_at: nil)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
      provider: "hack_club", uid: user.hca_uid,
      extra: { raw_info: { verification_status: status, ysws_eligible: eligible } }
    )
    post "/auth/hack_club"
    follow_redirect!
    user.update_columns(verification_checked_at: checked_at) if checked_at
  end

  def in_state(state)
    case state
    when :unverified then sign_in_as(@user, status: "needs_submission", eligible: false)
    when :not_eligible then sign_in_as(@user, eligible: false)
    when :stale then sign_in_as(@user, checked_at: 31.days.ago)
    when :ready then sign_in_as(@user)
    end
  end

  def place_order(prize_key: "tshirt", key: SecureRandom.hex(8)) = post_order_as(@user, prize_key: prize_key, key: key)

  def approved_ship
    (7..9).each { |day| code(@user, D[day], HOUR) }
    ship = submit_ship(make_project(@user))
    travel_to(HOURS_NOW) { Ships::Approve.call(ship: ship, reviewer: users(:new_user), approved_seconds: 3 * HOUR, now: Time.current) }
    ship
  end

  # --- the shop page ---

  test "flag on, verified but not eligible: coins show as locked, a kind note, no way to buy, never a reason" do
    give_coins(@user, 120)
    with_feature(:eligibility_gate) do
      in_state :not_eligible
      get shop_path
      assert_response :success
      assert_select "#coin-total", text: "120 coins"
      assert_select "#coin-spendable", text: "0 coins"
      assert_select "#shop-verify-note", text: /#{Regexp.escape(NOT_ELIGIBLE)} #{Regexp.escape(HELP)}/
      assert_select "#shop-verify-note .badge", text: /Locked for now/
      assert_select "#shop-verify-note a", count: 0
      assert_select "#shop-verify-note form", count: 0
      assert_select ".shop-item a", text: "Get this", count: 0
      assert_select ".shop-item button[disabled]", text: "Not available yet", count: Prize.paid.size
      assert_select ".shop-balance .badge--success", count: 0
      assert_no_match(/Locked until you verify/, response.body)
    end
  end

  test "flag on, not verified: the verify note and buttons are the ones from before the gate" do
    give_coins(@user, 120)
    with_feature(:eligibility_gate) do
      in_state :unverified
      get shop_path
      assert_select "#shop-verify-note", /unlock when you verify your identity with Hack Club/
      assert_select "#shop-verify-note a[href='https://auth.hackclub.com']", text: "Verify with Hack Club"
      assert_select ".shop-item button[disabled]", text: "Locked until you verify", count: Prize.paid.size
      assert_select "#shop-verify-note", text: /qualify/, count: 0
    end
  end

  test "flag on, verified and eligible: ready to spend, no note" do
    give_coins(@user, 120)
    with_feature(:eligibility_gate) do
      in_state :ready
      get shop_path
      assert_select "#shop-verify-note", 0
      assert_select "#coin-spendable", text: "120 coins"
      assert_select ".shop-balance .badge--success", text: "Verified"
      assert_select ".shop-item a", text: "Get this"
    end
  end

  test "flag on, a verification older than the maximum age: sign in again, with a button into the existing sign-in" do
    give_coins(@user, 120)
    with_feature(:eligibility_gate) do
      in_state :stale
      get shop_path
      assert_select "#coin-total", text: "120 coins"
      assert_select "#coin-spendable", text: "0 coins"
      assert_select "#shop-verify-note", text: /#{Regexp.escape(RECHECK)}/
      assert_select "#shop-verify-note form[action='/auth/hack_club'][method=post] button", text: "Sign in again"
      assert_select ".shop-item button[disabled]", text: "Sign in to refresh", count: Prize.paid.size
      assert_select ".shop-item a", text: "Get this", count: 0
    end
  end

  test "flag off: a verified person who is not eligible, or whose check is ancient, spends exactly as before" do
    give_coins(@user, 120)
    without_feature(:eligibility_gate) do
      sign_in_as @user, eligible: false, checked_at: 400.days.ago
      get shop_path
      assert_select "#shop-verify-note", 0
      assert_select "#coin-spendable", text: "120 coins"
      assert_select ".shop-item a", text: "Get this"
      get shop_item_path("tshirt")
      assert_response :success
      assert_difference "Order.count", 1 do
        place_order
      end
      assert_redirected_to order_path(Order.last)
    end
  end

  # --- confirm page and buying ---

  test "the confirm page and the order are refused in every locked state, with the matching words, and nothing is written" do
    give_coins(@user, 120)
    with_feature(:eligibility_gate) do
      { not_eligible: "#{NOT_ELIGIBLE} #{HELP}", stale: RECHECK, unverified: "Coins unlock when you verify your identity with Hack Club." }.each do |state, words|
        in_state state
        get shop_item_path("tshirt")
        assert_redirected_to shop_path
        assert_equal words, flash[:alert], state.to_s

        assert_no_difference [ "Order.count", "CoinTransaction.count" ] do
          place_order
        end
        assert_redirected_to shop_path
        assert_equal words, flash[:alert], state.to_s
      end
      assert_equal 120, Coins::Balance.total(@user)
    end
  end

  test "flag on, verified and eligible: confirm page and order work" do
    give_coins(@user, 120)
    with_feature(:eligibility_gate) do
      in_state :ready
      get shop_item_path("tshirt")
      assert_response :success
      assert_difference "Order.count", 1 do
        place_order
      end
      assert_equal 70, Coins::Balance.total(@user)
    end
  end

  test "signing in again turns a stale verification back into a ready one" do
    give_coins(@user, 120)
    with_feature(:eligibility_gate) do
      in_state :stale
      place_order
      assert_equal RECHECK, flash[:alert]
      sign_in_as @user
      assert_difference "Order.count", 1 do
        place_order
      end
    end
  end

  test "the free sticker stays open to everyone whatever their eligibility (a decision for the owner)" do
    with_feature(:eligibility_gate) do
      in_state :not_eligible
      get shop_path
      assert_select ".shop-sticker", text: /No coins needed\./
      assert_select ".shop-sticker", text: /don't have to be verified/, count: 0
      assert_difference "Order.where(kind: 'signup_sticker').count", 1 do
        claim_sticker_as @user
      end
    end
  end

  # --- the dashboard, the ships and the form ---

  test "dashboard coins panel in each state" do
    give_coins(@user, 40)
    with_feature(:eligibility_gate) do
      in_state :not_eligible
      get dashboard_path
      assert_select ".dash-coins strong", "40 coins"
      assert_select ".dash-coins", /Spendable now:\s*0 coins/
      assert_select ".dash-coins .ship-note", text: /#{Regexp.escape(NOT_ELIGIBLE)} #{Regexp.escape(HELP)}/
      assert_select ".dash-coins .ship-note a", count: 0
      assert_select ".dash-coins a[href='#{shop_path}']"

      in_state :stale
      get dashboard_path
      assert_select ".dash-coins .ship-note", text: /#{Regexp.escape(RECHECK)}/
      assert_select ".dash-coins .ship-note form[action='/auth/hack_club']"

      in_state :unverified
      get dashboard_path
      assert_select ".dash-coins .ship-note a[href='https://auth.hackclub.com']", "Verify with Hack Club"

      in_state :ready
      get dashboard_path
      assert_select ".dash-coins .ship-note", 0
      assert_select ".dash-coins", { text: /Spendable now/, count: 0 }
    end
  end

  test "dashboard flag off: verified but not eligible shows no note" do
    give_coins(@user, 40)
    without_feature(:eligibility_gate) do
      sign_in_as @user, eligible: false
      get dashboard_path
      assert_select ".dash-coins .ship-note", 0
    end
  end

  test "ship detail and the ships list carry the same note in each state" do
    ship = approved_ship
    with_feature(:eligibility_gate) do
      [ ship_path(ship), ships_path ].each do |path|
        in_state :not_eligible
        get path
        assert_select ".ship-note", text: /#{Regexp.escape(NOT_ELIGIBLE)} #{Regexp.escape(HELP)}/

        in_state :stale
        get path
        assert_select ".ship-note", text: /#{Regexp.escape(RECHECK)}/

        in_state :unverified
        get path
        assert_select ".ship-note", text: /Your coins unlock when you verify your identity with Hack Club/

        in_state :ready
        get path
        assert_select ".ship-note", 0
      end
    end
  end

  test "shipping is never blocked: the ship form says so for a person who cannot spend, and still submits" do
    (7..9).each { |day| code(@user, D[day], HOUR) }
    project = make_project(@user)
    with_feature(:eligibility_gate) do
      in_state :not_eligible
      get new_project_ship_path(project)
      assert_response :success
      assert_select ".ship-note", text: /You can ship any time\./
      assert_select ".ship-note", text: /#{Regexp.escape(NOT_ELIGIBLE)}/
      assert_select "button[name=ship_action][value=submit]"

      assert_difference "Ship.count", 1 do
        post project_ships_path(project), params: { ship: ship_attrs, ship_action: "submit" }
      end
    end
  end

  test "flag off, the ship form for a verified person has no note whatever their eligibility" do
    project = make_project(@user)
    (7..9).each { |day| code(@user, D[day], HOUR) }
    without_feature(:eligibility_gate) do
      sign_in_as @user, eligible: false
      get new_project_ship_path(project)
      assert_select ".ship-note", 0
    end
  end

  # --- Slack text ---

  test "the ship_approved Slack sentence follows the same three states" do
    with_feature(:eligibility_gate) do
      @user.update_columns(verification_status: "verified", ysws_eligible: false, verification_checked_at: Time.current)
      assert_equal " Your coins are saved, but prizes are only available to people who qualify for Hack Club YSWS programs. #{HELP}",
                   Notifications::Message.unlock_note(@user)
      @user.update_columns(verification_checked_at: 40.days.ago)
      assert_equal " #{RECHECK} Your coins are saved and you keep earning.", Notifications::Message.unlock_note(@user)
      @user.update_columns(verification_status: "needs_submission")
      assert_includes Notifications::Message.unlock_note(@user), "unlock when you verify your identity with Hack Club"
      eligible!(@user)
      assert_equal "", Notifications::Message.unlock_note(@user)
    end
    without_feature(:eligibility_gate) do
      @user.update_columns(verification_status: "verified", ysws_eligible: false)
      assert_equal "", Notifications::Message.unlock_note(@user)
    end
  end

  # --- staff ---

  test "staff pages show the eligibility next to verification when the flag is on, and nothing new when it is off" do
    buyer = users(:new_user)
    buyer.update_columns(display_name: "Casey Teen", slack_id: "U0CASEY", onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4,
                         created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    verified!(buyer)
    give_coins(buyer, 200)
    order = buy(buyer, "tshirt")
    (7..9).each { |day| code(buyer, D[day], HOUR) }
    ship = submit_ship(make_project(buyer, name: "Cow Game"))
    ENV["ADMIN_HCA_UIDS"] = @user.hca_uid
    sign_in_as @user

    without_feature(:eligibility_gate) do
      get admin_orders_path
      assert_select "#order-#{order.id}", text: /Identity: verified\z|Identity: verified(?!, )/
      assert_select "#order-#{order.id}", text: /YSWS/, count: 0
      get admin_ship_path(ship)
      assert_select ".admin-dl", text: /YSWS/, count: 0
    end

    with_feature(:eligibility_gate) do
      buyer.update_columns(ysws_eligible: false, verification_checked_at: Time.current)
      get admin_orders_path
      assert_select "#order-#{order.id}", text: /Identity: verified, YSWS eligible: no/
      get admin_ship_path(ship)
      assert_select ".admin-dl", text: /Verified\s+YSWS eligible: no \(coins stay locked\)/

      buyer.update_columns(ysws_eligible: true)
      get admin_orders_path
      assert_select "#order-#{order.id}", text: /Identity: verified, YSWS eligible: yes/
      assert_select "#order-#{order.id}", text: /needs re-check/, count: 0
      get admin_ship_path(ship)
      assert_select ".admin-dl", text: /YSWS eligible: yes/

      buyer.update_columns(verification_checked_at: 45.days.ago)
      get admin_orders_path
      assert_select "#order-#{order.id}", text: /needs re-check/
      get admin_ship_path(ship)
      assert_select ".admin-dl", text: /verification needs a re-check/
    end
  end

  # --- nothing leaks, access is unchanged ---

  test "no page, flash or Slack text gives a reason or the raw flag" do
    give_coins(@user, 40)
    ship = approved_ship
    with_feature(:eligibility_gate) do
      in_state :not_eligible
      bodies = [ shop_path, dashboard_path, ship_path(ship), ships_path ].map do |path|
        get path
        response.body
      end
      get shop_item_path("tshirt")
      confirm_alert = flash[:alert]
      place_order
      order_alert = flash[:alert]
      assert_equal "#{NOT_ELIGIBLE} #{HELP}", confirm_alert
      assert_equal confirm_alert, order_alert
      bodies.push(confirm_alert, order_alert, Notifications::Message.unlock_note(@user))
      bodies.each do |body|
        assert_no_match(/ysws_eligible|because|your age|birth|address|country|school/i, body.to_s.sub("YSWS programs", ""))
      end
    end
  end

  test "the gate adds no route and leaves access alone: signed-out visitors and non-admins are turned away as before" do
    with_feature(:eligibility_gate) do
      get shop_path
      assert_redirected_to root_path
      post orders_path, params: { prize_key: "tshirt", idempotency_key: "k" }
      assert_redirected_to root_path
      in_state :not_eligible
      get admin_orders_path
      assert_response :not_found
      get admin_ship_path(approved_ship)
      assert_response :not_found
    end
  end

  test "the Flipper admins group lets staff dogfood the gate on themselves before it is on for everyone" do
    ENV["ADMIN_HCA_UIDS"] = @user.hca_uid
    other = users(:new_user)
    [ @user, other ].each { |user| user.update_columns(verification_status: "verified", ysws_eligible: false, verification_checked_at: Time.current) }
    Flipper.enable_group(:eligibility_gate, :admins)
    assert_equal :not_eligible, @user.spend_state
    assert_equal :ready, other.spend_state
  end

  # --- sign-in refreshes the check ---

  test "every sign-in stores when verification and eligibility were last copied from Hack Club" do
    travel_to Time.utc(2026, 11, 20, 9) do
      sign_in_as @user, checked_at: Time.utc(2026, 9, 1)
      assert_equal Time.utc(2026, 9, 1), @user.reload.verification_checked_at

      sign_in_as @user, eligible: false
      assert_equal Time.utc(2026, 11, 20, 9), @user.reload.verification_checked_at
      assert_not @user.ysws_eligible?
    end
  end

  test "a brand-new account gets its check time at first sign-in" do
    travel_to Time.utc(2026, 11, 20, 9) do
      OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: "ident!brand-new",
                                                                    extra: { raw_info: { verification_status: "verified", ysws_eligible: true } })
      post "/auth/hack_club"
      follow_redirect!
      assert_equal Time.utc(2026, 11, 20, 9), User.find_by!(hca_uid: "ident!brand-new").verification_checked_at
    end
  end
end
