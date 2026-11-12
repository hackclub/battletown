require "test_helper"
require_relative "../support/admin_sign_in"
require_relative "../support/ships_test_support"
require_relative "../support/shop_helper"
require_relative "../support/bosses_helper"

# Every staff action that changes something writes one row in the audit trail (AdminAudit). This reads the router, so a new
# staff write route fails here until it is either listed below with the audit action it must write, or listed as NOT_AUDITED
# with the reason. Each audited route is then driven as an admin and must add a row with that action whose subject and
# metadata carry no personal data.
class AdminAuditCoverageTest < ActionDispatch::IntegrationTest
  include AdminSignIn
  include ShipsTestSupport
  include ShopTestHelper

  WRITE_VERBS = %w[POST PATCH PUT DELETE].freeze

  # Staff writes that change nothing, so there is nothing to audit.
  NOT_AUDITED = {
    "POST /admin/users/:user_id/hours/confirm" => "the confirm step of an hours adjustment: it only shows the summary; the write is POST .../hours",
    "POST /admin/users/:user_id/coins/confirm" => "the confirm step of a coin adjustment: it only shows the summary; the write is POST .../coins"
  }.freeze

  setup do
    Flipper.enable(:team)
    Flipper.enable(:quests)
    Flipper.enable(:merch_track)
    Flipper.enable(:ship_screenshots)
    Flipper.enable(:nps)
    @admin = users(:onboarded)
    @teen = users(:new_user)
    @teen.update_columns(onboarded_at: Time.utc(2026, 11, 2), onboarding_step: 4, created_at: Time.utc(2026, 11, 1, 12), signed_up_on: Date.new(2026, 11, 1), display_name: "Pat Teen")
    verified!(@teen)
    give_coins(@teen, 500)
    @boss = Bosses::Seed.call && Boss.chronological.last
    as_admin(@admin)
  end

  def route_key(verb, path) = "#{verb} #{path.sub('(.:format)', '')}"

  def write_routes
    Rails.application.routes.routes.filter_map do |route|
      next unless route.defaults[:controller] && route.path.spec.to_s.start_with?("/admin/")

      verb = route.verb.to_s.gsub(/[^A-Z|]/, "").split("|").first
      route_key(verb, route.path.spec.to_s) if WRITE_VERBS.include?(verb)
    end.uniq
  end

  def a_ship(name:, hackatime:)
    project = make_project(@teen, name: name, hackatime: hackatime)
    code(@teen, Date.new(2026, 11, 8), HOUR, hackatime: hackatime)
    submit_ship(project)
  end

  def an_order(prize = "tshirt") = buy(@teen, prize, address: true)

  # route key => [audit action, a lambda that makes the request]. Records are made when the lambda runs.
  def table
    order = nil
    weeks = Boss.chronological.map(&:starts_on).select { |day| day > Date.current }
    {
      "POST /admin/users/:user_id/hours" => [ "hours_adjusted", -> { post admin_user_hours_adjustment_path(@teen), params: { direction: "add", date: "2026-11-10", minutes: "30", reason: "Hackatime missed a session", token: AdminUsers::Adjustment.new_token, confirmed: "1" } } ],
      "POST /admin/users/:user_id/coins" => [ "coins_adjusted", -> { post admin_user_coin_adjustment_path(@teen), params: { direction: "add", coins: "25", reason: "Missing ship payout", token: AdminUsers::Adjustment.new_token, confirmed: "1" } } ],
      "POST /admin/users/:user_id/notes" => [ "user_note_added", -> { post admin_user_notes_path(@teen), params: { note: "Wrote to them about missing hours." } } ],
      "POST /admin/nps/:id/reveal" => [ "nps_comment_author_viewed", -> { post admin_nps_reveal_path(NpsResponse.create!(user: @teen, score: 3, comment: "words", answered_at: Time.current, prompt_window_date: Date.current)) } ],
      "POST /admin/orders/export" => [ "order_exported", -> { post export_admin_orders_path } ],
      "PATCH /admin/orders/:id/hold" => [ "order_held", -> { order = an_order; patch hold_admin_order_path(order) } ],
      "PATCH /admin/orders/:id/release" => [ "order_released", -> { patch release_admin_order_path(order) } ],
      "PATCH /admin/orders/:id/ship" => [ "order_shipped", -> { patch ship_admin_order_path(order), params: { tracking: { carrier: "ups", number: "1Z999AA10123456784" } } } ],
      "PATCH /admin/orders/:id/tracking" => [ "order_tracking_updated", -> { patch tracking_admin_order_path(order), params: { tracking: { carrier: "ups", number: "1Z999AA10123456785" } } } ],
      "POST /admin/orders/:id/note" => [ "order_note_added", -> { post note_admin_order_path(order), params: { note: "Packed in the blue box." } } ],
      "POST /admin/orders/:id/address/reveal" => [ "order_address_revealed", -> { post reveal_address_admin_order_path(order) } ],
      "PATCH /admin/orders/:id/fulfil" => [ "order_fulfilled", -> { patch fulfil_admin_order_path(order) } ],
      "PATCH /admin/orders/:id/refund" => [ "order_refunded", -> { patch refund_admin_order_path(order), params: { reason_code: "other", confirm: "refund" } } ],
      "PATCH /admin/orders/:id/cancel" => [ "order_cancelled", -> { patch cancel_admin_order_path(an_order("keychain")), params: { reason_code: "buyer_request", confirm: "cancel" } } ],
      "POST /admin/projects/:id/flag" => [ "project_flagged", -> { post flag_admin_project_path(make_project(@teen, name: "Flag me", hackatime: nil)), params: { reason_preset: "Other", details: "looks copied" } } ],
      "POST /admin/projects/:id/ok" => [ "project_reviewed", -> { post ok_admin_project_path(make_project(@teen, name: "Fine one", hackatime: nil)) } ],
      "POST /admin/projects/:id/clear" => [ "project_cleared", -> { project = make_project(@teen, name: "Clear me", hackatime: nil); Projects::Review.flag(project: project, reviewer: @admin, preset: "Other", details: "x"); post clear_admin_project_path(project) } ],
      "POST /admin/projects/:id/note" => [ "project_note_added", -> { project = make_project(@teen, name: "Note me", hackatime: nil); Projects::Review.ok(project: project, reviewer: @admin); post note_admin_project_path(project), params: { note: "Checked the repo." } } ],
      "POST /admin/shop" => [ "shop_item_created", -> { post "/admin/shop", params: { shop_item: { key: "pixel_pin", name: "Pixel pin", description: "A tiny pin.", emoji: "📌", coins: "25", tier: "shop", position: "", active: "1" } } } ],
      "PATCH /admin/shop/:key" => [ "shop_item_updated", -> { patch "/admin/shop/tshirt", params: { shop_item: { coins: "55" } } } ],
      "PATCH /admin/shop/:key/archive" => [ "shop_item_archived", -> { patch "/admin/shop/tshirt/archive" } ],
      "PATCH /admin/shop/:key/restore" => [ "shop_item_restored", -> { ShopItem.find_by!(key: "tshirt").update!(active: false); patch "/admin/shop/tshirt/restore" } ],
      "PATCH /admin/shop/:key/move" => [ "shop_item_reordered", -> { patch "/admin/shop/keychain/move", params: { direction: "up" } } ],
      "PATCH /admin/ships/:id/approve" => [ "ship_approved", -> { patch approve_admin_ship_path(a_ship(name: "Approve me", hackatime: "approve-me")) } ],
      "PATCH /admin/ships/:id/reject" => [ "ship_rejected", -> { patch reject_admin_ship_path(a_ship(name: "Reject me", hackatime: "reject-me")), params: { reason_note: "Needs a working demo." } } ],
      "DELETE /admin/ships/:ship_id/images/:position" => [ "ship_screenshot_removed", -> { delete_screenshot } ],
      "PATCH /admin/bosses/:id" => [ "boss_updated", -> { patch admin_boss_path(future_boss), params: { boss: { name: "The Linter", art_key: "placeholder" } } } ],
      "POST /admin/quests" => [ "quest_created", -> { post "/admin/quests", params: { quest: { starts_on: weeks.first.iso8601, goal_key: "code_days", target: "3", reward_coins: "20" } } } ],
      "PATCH /admin/quests/:id" => [ "quest_updated", -> { patch "/admin/quests/#{Quest.create!(starts_on: weeks.second, goal_key: "code_days", target: 3, reward_coins: 20).id}", params: { quest: { reward_coins: "25" } } } ],
      "DELETE /admin/teams/:id" => [ "crew_dissolved", -> { delete "/admin/teams/#{Team.create!(name: "Crew", invite_token: Team.new_token, invite_expires_at: 1.day.from_now).id}" } ],
      "PATCH /admin/merch/:id/fulfill" => [ "merch_claim_fulfilled", -> { patch "/admin/merch/#{a_claim.id}/fulfill" } ],
      "PATCH /admin/merch/:id/cancel" => [ "merch_claim_cancelled", -> { patch "/admin/merch/#{a_claim.id}/cancel" } ]
    }
  end

  # The PUT twins of PATCH routes share the action.
  PUT_TWINS = { "PUT /admin/bosses/:id" => "PATCH /admin/bosses/:id", "PUT /admin/quests/:id" => "PATCH /admin/quests/:id" }.freeze

  def future_boss = Boss.chronological.reject { |boss| boss.starts_on <= Date.current }.first || Boss.create!(name: "Later boss", art_key: "placeholder", starts_on: Date.current + 30, ends_on: Date.current + 36, hp_seconds: 3600)

  def a_claim = MerchClaim.create!(user: @teen, boss: Boss.chronological.to_a[(@claims = @claims.to_i + 1)], item_key: "k#{SecureRandom.hex(3)}", item_name: "Sticker", claimed_at: Time.current)

  def delete_screenshot
    ship = a_ship(name: "Has picture", hackatime: "has-picture")
    ShipImage.create!(ship: ship, user: @teen, position: 1, content: "RIFFxxxxWEBP", byte_size: 12, width: 1, height: 1, sha256: "a" * 64)
    delete "/admin/ships/#{ship.id}/images/1"
  end

  test "every staff write route is either audited by this table or listed as changing nothing" do
    known = table.keys + PUT_TWINS.keys + NOT_AUDITED.keys
    assert_empty write_routes - known, "a staff write route has no audit expectation: add it to AdminAuditCoverageTest#table (or NOT_AUDITED with the reason)"
    assert_empty known - write_routes, "the table lists a route the router does not have"
  end

  test "every audited staff write adds an audit row with its action, a subject and no personal data" do
    expectations = table
    expectations.each do |key, (action, request)|
      before = AdminAuditEvent.maximum(:id).to_i
      instance_exec(&request)
      assert_includes [ 200, 302, 303 ], response.status, "#{key} answered #{response.status}: #{response.body.to_s[0, 300]}"
      events = AdminAuditEvent.where("id > ?", before).where(action: action).to_a
      assert_equal 1, events.size, "#{key} must write exactly one #{action} audit row, wrote #{AdminAuditEvent.where('id > ?', before).pluck(:action).inspect}"
      event = events.first
      assert_equal @admin.id, event.actor_id, key
      assert event.subject_type.present? && event.subject_id.present?, key
      assert_empty AdminAudit::Metadata.problems(event.metadata), key
      assert_no_match(/Pat Teen|example\.test|@/, event.metadata.to_json, "#{key} audit metadata holds something personal")
    end
  end

  test "the feature-flag console is audited too: changing a flag writes a row, looking at it does not" do
    Flipper.add(:z2_probe)
    get "/admin/flipper/features/z2_probe"
    assert_response :success
    before = AdminAuditEvent.count
    assert_equal before, AdminAuditEvent.count, "viewing the console is not a change"
    token = css_select("input[name=authenticity_token]").first&.[]("value")
    assert token.present?, "the console page carries its own form token"
    post "/admin/flipper/features/z2_probe/boolean", params: { action: "Enable", authenticity_token: token }
    assert_includes [ 302, 303 ], response.status
    assert_predicate Flipper[:z2_probe], :on?
    assert_equal before + 1, AdminAuditEvent.count, "a change made in the flag console must be audited"
    event = AdminAuditEvent.order(:id).last
    assert_equal "feature_flag_changed", event.action
    assert_equal @admin.id, event.actor_id
    assert_equal({ "http_method" => "post", "feature" => "z2_probe", "gate" => "boolean" }, event.metadata)
    post "/admin/flipper/features/z2_probe/boolean", params: { action: "Disable", authenticity_token: "forged" }
    assert_response :forbidden
    assert_equal before + 1, AdminAuditEvent.count, "a refused request is not a change"
  end
end
