require "test_helper"

# Builds one user with at least one row in EVERY table that holds something about a person (all the flagged features
# included), for the data-deletion tests. A new table that references users must get a row here: the schema guard
# and the all-flags deletion test fail until it does.
module EveryTableRows
  def user_with_rows_in_every_table
    user = users(:onboarded)
    Notification.create!(user: user, kind: "daily_reminder", status: "sent", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "guard-#{user.id}")
    HourEntry.create!(user: user, local_date: Date.new(2026, 11, 10), seconds: 600, source: "manual", note: "guard", idempotency_key: "guard-#{user.id}")
    NotificationPreference.create!(user: user, kind: "ship_reminder", enabled: false)
    project = Project.create!(user: user, name: "Guard project", kind: "game")
    project.hackatime_links.create!(user_id: user.id, hackatime_project: "guard-project", link_method: "manual")
    project.link_suggestions.create!(hackatime_project: "guard-other")
    Projects::Review.flag(project: project, reviewer: users(:new_user), preset: "Other", details: "guard") # reaches the teen only through the project
    CoinTransaction.create!(user: user, amount: 5, kind: "refund", idempotency_key: "guard-#{user.id}")
    guard_order = Order.create!(user: user, prize_key: "sticker_pack", prize_name: "Sticker pack", coins: 20, kind: "purchase", idempotency_key: "guard-#{user.id}")
    OrderEvent.create!(order: guard_order, actor_kind: "staff", action: "note_added", from_status: "requested", to_status: "requested", note: "guard")
    OrderAddress.create!(order: guard_order, user: user, recipient_name: "Guard Person", line_1: "1 Example Street", city: "Exampleville", country: "US")
    AddressOffer.create!(user: user, draft_key: "guard-#{user.id}", payload: "[]", expires_at: 10.minutes.from_now)
    HourEntry.create!(user: user, local_date: Date.new(2026, 11, 9), seconds: 3600, source: "manual", note: "guard", hackatime_project: "guard-project", idempotency_key: "guard-ship-#{user.id}")
    Ship.create!(user: user, project: project, status: "submitted", description: "Guard ship", repo_url: "https://github.com/guard/ship", coded_seconds: 3600,
                 window_start_date: Date.new(2026, 11, 9), window_end_date: Date.new(2026, 11, 9), daily_seconds: { "2026-11-09" => 3600 }, submitted_at: Time.current)
    ShipImage.create!(ship: Ship.find_by!(user: user), user: user, position: 1, content: "RIFFguard", byte_size: 9, width: 1, height: 1, sha256: "a" * 64)
    DailyResult.create!(user: user, local_date: Date.new(2026, 11, 1), raw_seconds: 0, quick_met: false, goal_met: false,
                        streak_15: 0, goal_streak: 0, freeze_available: true)
    WelcomeBackWindow.create!(user: user, starts_on: Date.new(2026, 11, 8), ends_on: Date.new(2026, 11, 10), idle_days: 7)
    HackatimeConnection.create!(user: user, hackatime_uid: "1", access_token: "guard-token", scopes: "profile read", connected_at: Time.current)
    HackatimeDayWindow.create!(user: user, local_date: Date.new(2026, 11, 9), starts_at: Time.utc(2026, 11, 9), ends_at: Time.utc(2026, 11, 10), hackatime_uid: "1")
    guard_boss = Boss.create!(name: "Guard boss", art_key: "placeholder", starts_on: Date.new(2099, 1, 2), ends_on: Date.new(2099, 1, 8), hp_seconds: 3600)
    MerchClaim.create!(user: user, boss: guard_boss, item_key: "guard_item", item_name: "Guard item", claimed_at: Time.current)
    guard_quest = Quest.create!(starts_on: guard_boss.starts_on, goal_key: "add_project", reward_coins: 15)
    QuestCompletion.create!(user: user, quest: guard_quest, completed_at: Time.current, coin_transaction: CoinTransaction.find_by!(user: user, idempotency_key: "guard-#{user.id}"))
    PlinkoDrop.create!(user: user, dropped_at: Time.current, local_date: Date.new(2026, 11, 9), slot: 4, points: 50, seed: 1, idempotency_key: "guard-drop-#{user.id}")
    PlinkoPlayer.create!(user: user, nickname: "Guard Otter #{user.id}", leaderboard_opt_in: true)
    NpsResponse.create!(user: user, score: 9, comment: "guard", answered_at: Time.current, prompt_window_date: Date.new(2026, 11, 9))
    crew = Team.create!(name: "Guard crew", invite_token: Team.new_token, invite_expires_at: 1.day.from_now)
    TeamMembership.create!(team: crew, user: user, joined_at: Time.current)
    TeamCooldown.create!(user: user, left_at: Time.current)
    TeamPayout.create!(user: user, ship: Ship.find_by!(user_id: user.id), team: crew, coins: 1, matched_days: 1)
    UserNote.create!(user: user, author: users(:new_user), body: "guard note", created_at: Time.current)
    # The staff audit trail: a row about the person (Privacy::Deleter removes it), a row about one of their orders (kept, ids only)
    # and a row where they are the staff member who acted (the actor is nulled, never deleted: other people's history).
    AdminAudit.record!(actor: users(:new_user), action: "coins_adjusted", subject: user, metadata: { coins: 5, reason: "Jamie Doe asked on Slack" })
    AdminAudit.record!(actor: users(:new_user), action: "order_held", subject: guard_order, metadata: { order_id: guard_order.id })
    AdminAudit.record!(actor: user, action: "user_viewed", subject: users(:new_user))
    user
  end
end
