require "test_helper"
require_relative "../support/plinko_helper"

# The Plinko page, the drop endpoint, the leaderboard switch, the dashboard teaser and the admin page, with the flag
# off (everything is a 404 and nothing is written) and on.
class PlinkoTest < ActionDispatch::IntegrationTest
  include PlinkoHelper

  setup do
    OmniAuth.config.test_mode = true
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @alice = users(:onboarded) # display_name "Veteran", UTC
    @bob = users(:new_user)    # display_name "Newbie"
    @bob.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4, time_zone: "UTC")
    @today = Hours::Days.today(@alice)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def give_balls(user, count) = code_on(user, @today, minutes(5 * count))

  def drop(key: SecureRandom.hex(12), **options)
    post plinko_drops_path, params: { idempotency_key: key }, as: :json, **options
  end

  def json = JSON.parse(response.body)

  # --- flag off: nothing exists ---

  test "with the flag off every Plinko route is a 404 and nothing is written" do
    sign_in_as @alice
    give_balls(@alice, 2)

    assert_no_difference -> { PlinkoPlayer.count + PlinkoDrop.count } do
      get plinko_path
      assert_response :not_found
      post plinko_drops_path, params: { idempotency_key: SecureRandom.hex(12) }, as: :json
      assert_response :not_found
      patch leaderboard_plinko_path, params: { leaderboard_opt_in: "1" }
      assert_response :not_found
      post nickname_plinko_path
      assert_response :not_found
      get admin_plinko_path
      assert_response :not_found
    end
  end

  test "with the flag off the dashboard and the admin dashboard show nothing about Plinko and read no Plinko tables" do
    ENV["ADMIN_HCA_UIDS"] = @alice.hca_uid
    sign_in_as @alice
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/plinko/i) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      get dashboard_path
      assert_response :success
      assert_no_match(/Plinko/, response.body)
      assert_select "a[href^='/plinko']", false
      get admin_root_path
      assert_no_match(/Plinko/, response.body)
      assert_select "a[href^='/admin/plinko']", false
    end
    assert_empty queries
  end

  # --- flag on: the page ---

  test "the page needs a signed-in, onboarded player" do
    with_feature(:plinko) do
      get plinko_path
      assert_redirected_to root_path

      user = User.create!(hca_uid: "plinko-fresh-#{SecureRandom.hex(3)}")
      sign_in_as user
      get plinko_path
      assert_redirected_to onboarding_path
    end
  end

  test "the page shows balls, the board, the odds and the no-coins promise, and makes a player with the leaderboard off" do
    with_feature(:plinko) do
      sign_in_as @alice
      give_balls(@alice, 3)
      get plinko_path
      assert_response :success

      assert_select "h1", "Plinko"
      assert_select "[data-controller=plinko][data-plinko-balls-value='3']"
      assert_select "button[data-action='plinko#drop']:not([disabled])"
      assert_select "[data-plinko-target=sound][aria-pressed=true]"
      assert_select "canvas[role=img][aria-label]"
      assert_select "table caption", text: "Slot odds and points"
      assert_match(/do not turn into coins/, response.body)
      assert_select "input[type=checkbox][name=leaderboard_opt_in]:not([checked])"
      assert_not PlinkoPlayer.find_by!(user_id: @alice.id).leaderboard_opt_in
    end
  end

  test "with no balls the drop button is disabled" do
    with_feature(:plinko) do
      sign_in_as @alice
      get plinko_path
      assert_select "button[data-action='plinko#drop'][disabled]"
    end
  end

  test "the page has no inline script or style" do
    with_feature(:plinko) do
      sign_in_as @alice
      get plinko_path
      assert_select "script:not([src]):not([nonce])", false
      assert_select "[style]", false
    end
  end

  # --- the drop endpoint ---

  test "a drop with no ball is a 422 and writes nothing" do
    with_feature(:plinko) do
      sign_in_as @alice
      assert_no_difference -> { PlinkoDrop.count } do
        drop
      end
      assert_response :unprocessable_content
      assert_equal "no_balls", json["error"]
    end
  end

  test "a drop with a ball answers with the route, the slot and the points, decided by the server" do
    with_feature(:plinko) do
      sign_in_as @alice
      give_balls(@alice, 2)
      assert_difference -> { PlinkoDrop.count }, 1 do
        drop
      end
      assert_response :created

      body = json
      board = Plinko::Board.current
      assert_equal board.walk(body["seed"]), body["path"]
      assert_equal board.slot_for(body["path"]), body["slot"]
      assert_equal board.points_for(body["slot"]), body["points"]
      assert_equal 1, body["balls"]["available"]
      assert_equal body["points"], body["totals"]["today"]
      assert_equal body["points"], body["totals"]["all_time"]
      assert_equal({ "position" => 1, "players" => 1 }, body["rank"])
    end
  end

  test "the client cannot choose the slot, the points or the seed" do
    with_feature(:plinko) do
      sign_in_as @alice
      give_balls(@alice, 1)
      post plinko_drops_path, params: { idempotency_key: SecureRandom.hex(12), slot: 0, points: 999_999, seed: 1 }, as: :json
      assert_response :created
      drop = PlinkoDrop.find_by!(user_id: @alice.id)
      assert_not_equal 999_999, drop.points
      assert_not_equal 1, drop.seed
    end
  end

  test "the same idempotency key twice drops one ball and answers the same" do
    with_feature(:plinko) do
      sign_in_as @alice
      give_balls(@alice, 3)
      key = SecureRandom.hex(12)
      drop(key: key)
      first = json
      assert_no_difference -> { PlinkoDrop.count } do
        drop(key: key)
      end
      assert_response :ok
      assert_equal true, json["replayed"]
      assert_equal first.values_at("slot", "points", "path", "seed"), json.values_at("slot", "points", "path", "seed")
      assert_equal 2, json["balls"]["available"]
    end
  end

  test "a missing or malformed key is a 422" do
    with_feature(:plinko) do
      sign_in_as @alice
      give_balls(@alice, 1)
      post plinko_drops_path, params: {}, as: :json
      assert_response :unprocessable_content
      assert_equal "bad_key", json["error"]
      assert_equal 0, PlinkoDrop.count
    end
  end

  test "signed-out visitors and people who have not finished onboarding cannot drop" do
    with_feature(:plinko) do
      drop
      assert_response :unauthorized

      user = User.create!(hca_uid: "plinko-fresh-#{SecureRandom.hex(3)}")
      sign_in_as user
      drop
      assert_response :forbidden
      assert_equal 0, PlinkoDrop.count
    end
  end

  test "a drop without a CSRF token is rejected and writes nothing" do
    with_feature(:plinko) do
      sign_in_as @alice
      give_balls(@alice, 1)
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      begin
        assert_no_difference -> { PlinkoDrop.count } do
          drop
        end
        assert_response :unprocessable_content
      ensure
        ActionController::Base.allow_forgery_protection = original
      end
    end
  end

  test "dropping and joining the leaderboard never write the coins ledger" do
    with_feature(:plinko) do
      sign_in_as @alice
      give_balls(@alice, 3)
      assert_no_difference -> { CoinTransaction.count } do
        2.times { drop }
        patch leaderboard_plinko_path, params: { leaderboard_opt_in: "1" }
        post nickname_plinko_path
        get plinko_path
        get dashboard_path
      end
      assert_equal 0, CoinTransaction.where(user_id: @alice.id).count
    end
  end

  # --- the leaderboard: opt-in, nicknames only ---

  test "two players: only the one who opted in is listed, by nickname, and no real name or other personal data is ever sent" do
    with_feature(:plinko) do
      dropped_on(@alice, @today, slot: 0)
      dropped_on(@bob, @today, slot: 1)
      alice_nick = Plinko::Players.for(@alice).nickname
      bob_nick = Plinko::Players.for(@bob).nickname
      Plinko::Players.opt_in!(@bob, true)

      sign_in_as @alice
      get plinko_path
      page = response.body
      assert_select ".plinko__list li", 1
      assert_includes page, bob_nick
      assert_select ".plinko__list", text: /#{Regexp.escape(bob_nick)}/
      assert_select ".plinko__list", text: /#{Regexp.escape(alice_nick)}/, count: 0
      assert_select "input[type=checkbox][name=leaderboard_opt_in]:not([checked])"
      assert_match(/Your place this week: <strong>#1<\/strong> of 2 players/, page, "Alice sees her own rank although she is not listed")

      [ "Veteran", "Newbie", @alice.email, @bob.email, @alice.hca_uid, @bob.hca_uid ].each do |secret|
        assert_not_includes page, secret, "#{secret} must not appear on the Plinko page"
      end

      give_balls(@alice, 2) # one ball was already dropped above
      drop
      assert_response :created
      [ "Veteran", "Newbie", @alice.email, @bob.email, @bob.hca_uid ].each { |secret| assert_not_includes response.body, secret }
      assert_not_includes response.body, bob_nick
    end
  end

  test "someone who never opted in never appears, and opting out removes them again" do
    with_feature(:plinko) do
      sign_in_as @alice
      dropped_on(@alice, @today, slot: 0)
      get plinko_path
      assert_select ".plinko__list", false

      patch leaderboard_plinko_path, params: { leaderboard_opt_in: "1" }
      assert_redirected_to plinko_path
      follow_redirect!
      nick = PlinkoPlayer.find_by!(user_id: @alice.id).nickname
      assert_select ".plinko__list li.is-you", text: /#{Regexp.escape(nick)}/

      patch leaderboard_plinko_path, params: { leaderboard_opt_in: "0" }
      follow_redirect!
      assert_select ".plinko__list", false
      assert_not PlinkoPlayer.find_by!(user_id: @alice.id).leaderboard_opt_in
    end
  end

  test "the leaderboard setting only ever changes the signed-in player's own row" do
    with_feature(:plinko) do
      bob_player = Plinko::Players.for(@bob)
      sign_in_as @alice
      patch leaderboard_plinko_path, params: { leaderboard_opt_in: "1", user_id: @bob.id, id: bob_player.id }
      post nickname_plinko_path, params: { user_id: @bob.id }
      assert_not bob_player.reload.leaderboard_opt_in
      assert_equal bob_player.nickname, bob_player.reload.nickname
    end
  end

  test "a new nickname is different and still unique" do
    with_feature(:plinko) do
      sign_in_as @alice
      get plinko_path
      before = PlinkoPlayer.find_by!(user_id: @alice.id).nickname
      post nickname_plinko_path
      assert_redirected_to plinko_path
      assert_not_equal before, PlinkoPlayer.find_by!(user_id: @alice.id).nickname
    end
  end

  # --- dashboard teaser ---

  test "the dashboard shows the teaser with the number of balls only while the flag is on" do
    sign_in_as @alice
    give_balls(@alice, 4)
    get dashboard_path
    assert_select "#dash-plinko-title", false

    with_feature(:plinko) do
      get dashboard_path
      assert_select "#dash-plinko-title", "Plinko"
      assert_select ".dash-plinko strong", "4"
      assert_select ".dash-plinko a[href='#{plinko_path}']"
    end
  end

  # --- admin ---

  test "the admin page shows aggregates only, and is a 404 for non-admins and while the flag is off" do
    with_feature(:plinko) do
      dropped_on(@alice, @today)
      dropped_on(@bob, @today)
      Plinko::Players.opt_in!(@bob, true)
      nick = PlinkoPlayer.find_by!(user_id: @bob.id).nickname

      ENV["ADMIN_HCA_UIDS"] = "someone-else"
      sign_in_as @alice
      get admin_plinko_path
      assert_response :not_found

      ENV["ADMIN_HCA_UIDS"] = @alice.hca_uid
      get admin_plinko_path
      assert_response :success
      assert_select "h1", "Plinko"
      assert_select "dd", text: "2" # balls dropped, all time
      [ "Veteran", "Newbie", nick, @alice.email, @bob.email ].each { |secret| assert_not_includes response.body, secret }
      assert_select "main form", false, "no actions on the admin page"
      get admin_root_path
      assert_select "a[href='#{admin_plinko_path}']"
    end

    get admin_plinko_path
    assert_response :not_found
  end

  # --- throttle ---

  test "writes under /plinko are limited per address" do
    travel_to Time.utc(2030, 1, 1, 12)
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    with_feature(:plinko) do
      120.times { post plinko_drops_path, params: {}, as: :json, headers: { "REMOTE_ADDR" => "203.0.113.50" } }
      post plinko_drops_path, params: {}, as: :json, headers: { "REMOTE_ADDR" => "203.0.113.50" }
      assert_response :too_many_requests
      post plinko_drops_path, params: {}, as: :json, headers: { "REMOTE_ADDR" => "203.0.113.51" }
      assert_not_equal 429, response.status
    end
  ensure
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
    travel_back
  end
end
