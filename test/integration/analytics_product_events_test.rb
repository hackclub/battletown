require "test_helper"
require_relative "../support/shop_helper"
require_relative "../support/ships_test_support"

# The product events as people and staff really cause them: through the controllers and the existing *.battletown announcements, with
# the visit attached where a page was involved. (The service-level paths, retries and failures are in AnalyticsProductEventsTest.)
class AnalyticsProductEventsIntegrationTest < ActionDispatch::IntegrationTest
  include ShopTestHelper
  include ShipsTestSupport

  D = ->(day) { Date.new(2026, 11, day) }

  setup do
    OmniAuth.config.test_mode = true
    @original_admins = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    @user = users(:onboarded)
    @user.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1))
    @staff = users(:new_user)
    @staff.update_columns(created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1), onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed
    @original_admins.nil? ? ENV.delete("ADMIN_HCA_UIDS") : ENV["ADMIN_HCA_UIDS"] = @original_admins
  end

  def sign_in_as(user, headers: browser_headers)
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club", headers: headers
    follow_redirect!
  end

  def events(name) = AnalyticsEvent.where(name: name.to_s).order(:id)

  # ---- the armoury ----

  test "opening the armoury and an item record shop_viewed and shop_item_viewed on the visit" do
    sign_in_as @user
    get shop_path, headers: browser_headers
    assert_response :success
    get shop_item_path("tshirt"), headers: browser_headers

    viewed = assert_tracked(:shop_viewed)
    assert_equal({}, viewed.props)
    assert_equal @user.id, viewed.user_id
    assert_equal AnalyticsVisit.sole.id, viewed.visit_id
    assert_equal({ "item_key" => "tshirt" }, assert_tracked(:shop_item_viewed).props)
    assert_equal 1, events(:shop_viewed).count
  end

  test "a script, a prefetch and a person who sent Do Not Track leave no armoury view" do
    sign_in_as @user
    get shop_path # no user agent: a script
    get shop_path, headers: browser_headers("Sec-Purpose" => "prefetch")
    get shop_path, headers: browser_headers("DNT" => "1")
    assert_not_tracked :shop_viewed
  end

  test "a staff member browsing the armoury is never measured" do
    ENV["ADMIN_HCA_UIDS"] = @staff.hca_uid
    sign_in_as @staff
    get shop_path, headers: browser_headers
    assert_response :success
    assert_not_tracked :shop_viewed
    assert_equal 0, AnalyticsEvent.count
  end

  test "placing an order records order_placed with the price, and a refusal records why" do
    verified!(@user)
    give_coins(@user, 60)
    sign_in_as @user

    post_order_as @user, prize_key: "tshirt", key: "first-order"
    assert_response :redirect
    assert_equal({ "item_key" => "tshirt", "coins" => 50, "kind" => "purchase" }, assert_tracked(:order_placed).props)

    post_order_as @user, prize_key: "tshirt", key: "second-order"
    assert_equal({ "reason" => "insufficient_coins", "item_key" => "tshirt" }, assert_tracked(:purchase_refused).props)
    assert_equal 1, events(:order_placed).count

    post_order_as @user, prize_key: "tshirt", key: "first-order" # a double click
    assert_equal 1, events(:order_placed).count
  end

  test "claiming the free sticker records order_placed as a signup sticker" do
    sign_in_as @user
    claim_sticker_as @user
    assert_response :redirect

    assert_equal %w[signup_sticker 0], assert_tracked(:order_placed, kind: "signup_sticker").props.values_at("kind", "coins").map(&:to_s)
  end

  # ---- ships ----

  test "opening the ship form records ship_form_viewed; a project that already has a ship in progress does not" do
    project = make_project(@user)
    (7..9).each { |day| code(@user, D[day], HOUR) }
    sign_in_as @user

    get new_project_ship_path(project), headers: browser_headers
    assert_response :success
    assert_equal 1, events(:ship_form_viewed).count
    assert_equal AnalyticsVisit.sole.id, events(:ship_form_viewed).sole.visit_id

    submit_ship(project, submit: false)
    get new_project_ship_path(project), headers: browser_headers
    assert_response :redirect
    assert_equal 1, events(:ship_form_viewed).count
  end

  test "shipping from the form, then staff approving, record the whole ship trail with no names, text or reasons" do
    project = make_project(@user, name: "Cow Game PROBE-NAME")
    (7..9).each { |day| code(@user, D[day], HOUR) }
    sign_in_as @user
    post project_ships_path(project), params: { ship: ship_attrs(description: "PROBE-DESCRIPTION"), ship_action: "submit" }, headers: browser_headers
    assert_response :redirect
    assert_equal({ "hours_bucket" => "2-5", "nth" => "1", "after_rejection" => false }, events(:ship_submitted).sole.props)
    assert_equal @user.id, events(:ship_submitted).sole.user_id

    ship = Ship.sole
    ENV["ADMIN_HCA_UIDS"] = @staff.hca_uid
    reset!
    sign_in_as @staff
    patch "/admin/ships/#{ship.id}/approve", headers: browser_headers
    assert_response :redirect
    assert_equal "approved", ship.reload.status

    approved = events(:ship_approved).sole
    assert_equal [ @user.id, "2-5", "1" ], [ approved.user_id, approved.props["hours_bucket"], approved.props["nth"] ]
    assert_empty AnalyticsEvent.where(user_id: @staff.id), "the reviewer is not measured"
    assert_no_match(/PROBE/, AnalyticsEvent.pluck(:props).to_json)
  end

  test "withdrawing a waiting ship from the page records ship_withdrawn" do
    project = make_project(@user)
    (7..9).each { |day| code(@user, D[day], HOUR) }
    ship = submit_ship(project)
    sign_in_as @user
    patch withdraw_ship_path(ship), headers: browser_headers

    assert_equal "withdrawn", ship.reload.status
    assert_equal({ "nth" => "1" }, events(:ship_withdrawn).sole.props)
  end

  # ---- the dashboard to-do list ----

  test "saving a to-do list records todo_used once a day however often the page autosaves, and an empty list records nothing" do
    make_project(@user).update!(active: true)
    sign_in_as @user
    one = { todos: { "0" => { body: "Build the login form", done: "0" } } }

    patch dashboard_todos_path, params: { todos: {} }, as: :json, headers: browser_headers
    assert_not_tracked :todo_used

    patch dashboard_todos_path, params: one, as: :json, headers: browser_headers
    patch dashboard_todos_path, params: { todos: { "0" => { body: "A", done: "1" }, "1" => { body: "B", done: "0" } } }, as: :json, headers: browser_headers

    todo = events(:todo_used).sole
    assert_equal({ "items" => 1 }, todo.props)
    assert_equal @user.id, todo.user_id
    assert_no_match(/login/, todo.to_json)
  end

  # ---- NPS ----

  test "answering the survey records nps_answered with the score and band, and whether there was a comment, never the comment" do
    Flipper.enable(:nps)
    token = Nps::Token.generate(@user, Date.new(2026, 11, 12))
    post feedback_path(token), params: { nps: { score: "9", comment: "PROBE-COMMENT about the program" } }, headers: browser_headers

    event = events(:nps_answered).sole
    assert_equal({ "score" => 9, "band" => "promoter", "has_comment" => true }, event.props)
    assert_equal @user.id, event.user_id
    assert_nil event.visit_id
    assert_no_match(/PROBE/, event.to_json)

    post feedback_path(token), params: { nps: { score: "2" } }, headers: browser_headers # a second answer for the same survey
    assert_equal 1, events(:nps_answered).count
  end

  test "scores map to the NPS bands" do
    Flipper.enable(:nps)
    { 0 => "detractor", 6 => "detractor", 7 => "passive", 8 => "passive", 9 => "promoter", 10 => "promoter" }.each_with_index do |(score, band), index|
      user = User.create!(hca_uid: "ident!nps-#{index}-#{SecureRandom.hex(3)}")
      post feedback_path(Nps::Token.generate(user, Date.new(2026, 11, 12))), params: { nps: { score: score.to_s } }, headers: browser_headers
      assert_equal [ score, band, false ], events(:nps_answered).where(user_id: user.id).sole.props.values_at("score", "band", "has_comment")
    end
  end
end
