require "test_helper"
require_relative "../support/quests_helper"

class AdminQuestsTest < ActionDispatch::IntegrationTest
  include QuestsHelper

  setup do
    OmniAuth.config.test_mode = true
    @original_env = ENV["ADMIN_HCA_UIDS"]
    @detailed = Rails.application.env_config["action_dispatch.show_detailed_exceptions"]
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    travel_to QuestsHelper::NOW
    @admin = users(:onboarded)
    @boss = make_boss(starts_on: WEEK_START)
    @next_boss = make_boss(starts_on: WEEK_START + 7)
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

  def make_admin(user) = ENV["ADMIN_HCA_UIDS"] = user.hca_uid

  def quest_params(**attrs) = { quest: { starts_on: (WEEK_START + 7).iso8601, goal_key: "streak_days", target: "3", reward_coins: "20" }.merge(attrs) }

  test "signed-out visitors and non-admins get a 404 on every quests route, with the flag on" do
    quest = make_quest
    with_feature(:quests) do
      ENV["ADMIN_HCA_UIDS"] = "someone-else"
      [ nil, @admin ].each do |visitor|
        sign_in_as(visitor) if visitor
        [ [ :get, "/admin/quests" ], [ :get, "/admin/quests/new" ], [ :post, "/admin/quests" ], [ :get, "/admin/quests/#{quest.id}/edit" ],
          [ :patch, "/admin/quests/#{quest.id}" ] ].each do |verb, path|
          process(verb, path, params: quest_params)
          assert_response :not_found, "#{verb} #{path}"
        end
      end
      assert_equal 1, Quest.count
    end
  end

  test "flag off: even an admin gets a 404 and nothing is created" do
    without_feature(:quests) do
      make_admin(@admin)
      sign_in_as @admin
      get "/admin/quests"
      assert_response :not_found
      get "/admin/quests/new"
      assert_response :not_found
      post "/admin/quests", params: quest_params
      assert_response :not_found
      assert_equal 0, Quest.count

      get "/admin"
      assert_response :success
      assert_no_match(/Weekly quests/, response.body)
    end
  end

  test "an admin sees the link on the dashboard and the list, with aggregates only" do
    quest = make_quest(target: 2)
    user = quest_user
    entry = CoinTransaction.create!(user: user, amount: 15, kind: "quest_reward", idempotency_key: "k#{quest.id}")
    QuestCompletion.create!(user: user, quest: quest, completed_at: Time.current, coin_transaction: entry)
    QuestCompletion.create!(user: quest_user, quest: quest, completed_at: Time.current)
    user.update_columns(display_name: "Zebulon Quux", slack_id: "U0ZEBULON")

    with_feature(:quests) do
      make_admin(@admin)
      sign_in_as @admin
      get "/admin"
      assert_select "a[href='/admin/quests']", "Weekly quests"

      get "/admin/quests"
      assert_response :success
      assert_select ".admin-only"
      assert_select "table.admin-table tbody tr", 1
      assert_select "tbody tr:first-child td.num", text: "15"
      assert_select "tbody tr:first-child td.num", text: "2"
      assert_select "tbody tr:first-child td.num", text: "1"
      assert_no_match(/Zebulon|Quux|U0ZEBULON/, response.body)
      assert_select "a", text: "Edit", count: 0 # the week has started: no edit link
    end
  end

  test "an admin creates the quest for a boss week from the menu" do
    with_feature(:quests) do
      make_admin(@admin)
      sign_in_as @admin
      get "/admin/quests/new"
      assert_response :success
      assert_select "select[name='quest[starts_on]'] option", 3 # the blank and two weeks
      assert_select "select[name='quest[goal_key]'] option", Quests::Config.current.allowed_goals.size
      assert_select "input[name='quest[reward_coins]'][value='15']"

      assert_difference -> { Quest.count }, 1 do
        post "/admin/quests", params: quest_params
      end
      assert_redirected_to "/admin/quests"
      quest = Quest.find_by!(starts_on: WEEK_START + 7)
      assert_equal [ "streak_days", { "target" => 3 }, 20, WEEK_END + 7 ], [ quest.goal_key, quest.goal_params, quest.reward_coins, quest.ends_on ]

      get "/admin/quests"
      assert_select "td", "Code 3 days in a row"
      assert_select "a", text: "Edit", count: 1
    end
  end

  test "creating validates the week, the goal, the number and the reward, and names no unknown goal" do
    with_feature(:quests) do
      make_admin(@admin)
      sign_in_as @admin
      max = Quests::Config.current.max_reward_coins
      [ quest_params(starts_on: (WEEK_START + 8).iso8601), quest_params(starts_on: ""), quest_params(goal_key: "free_text"), quest_params(target: "99"),
        quest_params(target: ""), quest_params(goal_key: "ship_project", target: "2"), quest_params(reward_coins: (max + 1).to_s),
        quest_params(reward_coins: "0"), quest_params(starts_on: (WEEK_START - 14).iso8601) ].each do |params|
        assert_no_difference -> { Quest.count } do
          post "/admin/quests", params: params
        end
        assert_response :unprocessable_content, params.inspect
        assert_select ".alert--danger li"
      end

      make_quest(starts_on: WEEK_START + 7, goal_key: "add_project", target: nil)
      assert_no_difference -> { Quest.count } do
        post "/admin/quests", params: quest_params
      end
      assert_response :unprocessable_content
      assert_select ".alert--danger li", /already has a quest/
    end
  end

  test "a quest can be edited until its week starts" do
    quest = make_quest(starts_on: WEEK_START + 7, goal_key: "add_project", target: nil)
    with_feature(:quests) do
      make_admin(@admin)
      sign_in_as @admin
      get "/admin/quests/#{quest.id}/edit"
      assert_response :success
      assert_select ".admin-form-card form"
      assert_select "select[name='quest[starts_on]']", 0

      patch "/admin/quests/#{quest.id}", params: { quest: { goal_key: "code_days", target: "4", reward_coins: "25", starts_on: (WEEK_START + 14).iso8601 } }
      assert_redirected_to "/admin/quests"
      quest.reload
      assert_equal [ "code_days", 4, 25, WEEK_START + 7 ], [ quest.goal_key, quest.target, quest.reward_coins, quest.starts_on ], "the week never moves"

      patch "/admin/quests/#{quest.id}", params: { quest: { reward_coins: "9999" } }
      assert_response :unprocessable_content
      assert_equal 25, quest.reload.reward_coins
    end
  end

  test "after its week has started a quest cannot be edited, whatever the form says" do
    quest = make_quest(target: 2)
    with_feature(:quests) do
      make_admin(@admin)
      sign_in_as @admin
      get "/admin/quests/#{quest.id}/edit"
      assert_response :success
      assert_select ".admin-form-card", 0
      assert_select ".alert", /can no longer be changed/

      patch "/admin/quests/#{quest.id}", params: { quest: { reward_coins: "40" } }
      assert_response :unprocessable_content
      assert_equal 15, quest.reload.reward_coins
    end
  end

  test "admin writes keep CSRF protection" do
    original = ActionController::Base.allow_forgery_protection
    with_feature(:quests) do
      make_admin(@admin)
      sign_in_as @admin
      ActionController::Base.allow_forgery_protection = true
      post "/admin/quests", params: quest_params
      assert_includes [ 403, 422 ], response.status
      assert_equal 0, Quest.count
    end
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
