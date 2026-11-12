require "test_helper"

# Guards the data-deletion promise (docs/PRIVACY_API.md): Privacy::Deleter deletes the users row and relies on the
# database to cascade to everything about that person, and counts what each table lost. So a table that points at
# users must cascade, and a column that looks like it identifies a person must be covered by such a foreign key or be
# listed here, with the reason, as deliberately not personal. A new table that breaks this fails the suite until it
# is handled (add ON DELETE CASCADE, or decide what has to be retained and extend Privacy::Deleter::RETENTION_RULES).
class PrivacySchemaGuardTest < ActiveSupport::TestCase
  # Names that suggest a column holds a person's identity.
  PERSONAL_COLUMN = /user_id|slack|email|hca_uid|identity|ident_id|display_name|\bip\b|ip_address|phone|birth|address/

  # "table.column" => why it is not personal data. Nothing yet.
  NOT_PERSONAL = {}.freeze

  # Foreign keys to users that deliberately do NOT cascade, with the reason: the row is about someone else (the subject
  # of the row is reached through a cascading key), and the key is nulled so the staff member is forgotten.
  NULLIFY_ALLOWED = { "ships.reviewer_id" => "the staff member who reviewed a ship; the ship belongs to the teen" }.freeze

  # Tables that are not about a person: the Rails bookkeeping tables and the token ids of this very feature.
  EXEMPT_TABLES = %w[schema_migrations ar_internal_metadata privacy_request_tokens].freeze

  def connection = ActiveRecord::Base.connection

  def app_tables = connection.tables - EXEMPT_TABLES

  def user_foreign_keys(table) = connection.foreign_keys(table).select { |fk| fk.to_table == "users" }

  test "every foreign key to users cascades on delete" do
    referencing = app_tables.flat_map { |table| user_foreign_keys(table) }
    assert_includes referencing.map(&:from_table), "notifications", "the guard found no foreign keys at all"

    referencing.each do |fk|
      if NULLIFY_ALLOWED.key?("#{fk.from_table}.#{fk.column}")
        assert_equal :nullify, fk.on_delete, "#{fk.from_table}.#{fk.column} is listed as nulled on delete"
        next
      end

      assert_equal :cascade, fk.on_delete, "#{fk.from_table}.#{fk.column} references users without ON DELETE CASCADE: a person's data would survive (or block) deletion"
    end
  end

  test "tables that reference a table owned by a user cascade too" do
    owned = app_tables.select { |table| user_foreign_keys(table).any? { |fk| fk.on_delete == :cascade } }
    assert_includes owned, "notifications"
    app_tables.flat_map { |table| connection.foreign_keys(table) }.select { |fk| owned.include?(fk.to_table) }.each do |fk|
      assert_equal :cascade, fk.on_delete, "#{fk.from_table}.#{fk.column} references #{fk.to_table} (owned by a user) without ON DELETE CASCADE"
    end
  end

  test "columns that look personal are covered by a cascading foreign key or listed as not personal" do
    offenders = (app_tables - [ "users" ]).flat_map do |table|
      cascading = user_foreign_keys(table).select { |fk| fk.on_delete == :cascade || NULLIFY_ALLOWED.key?("#{fk.from_table}.#{fk.column}") }.map(&:column)
      connection.columns(table).map(&:name).select { |name| name.match?(PERSONAL_COLUMN) }
                .reject { |name| cascading.include?(name) || NOT_PERSONAL.key?("#{table}.#{name}") }.map { |name| "#{table}.#{name}" }
    end

    assert_empty offenders, "These look like personal data but are not a cascading foreign key to users. Make them one, or add them " \
                            "to NOT_PERSONAL with the reason (and handle them in Privacy::Deleter if they must go)"
  end

  test "the users table has the identifiers the subject finder matches on" do
    assert_equal %w[email hca_uid slack_id], (User.column_names & %w[email hca_uid slack_id]).sort
  end

  test "every table referencing users is counted when a user is deleted" do
    user = users(:onboarded)
    Notification.create!(user: user, kind: "daily_reminder", status: "sent", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "guard-#{user.id}")
    HourEntry.create!(user: user, local_date: Date.new(2026, 11, 10), seconds: 600, source: "manual", note: "guard", idempotency_key: "guard-#{user.id}")
    NotificationPreference.create!(user: user, kind: "ship_reminder", enabled: false)
    project = Project.create!(user: user, name: "Guard project", kind: "game")
    project.hackatime_links.create!(user_id: user.id, hackatime_project: "guard-project", link_method: "manual")
    project.link_suggestions.create!(hackatime_project: "guard-other")
    CoinTransaction.create!(user: user, amount: 5, kind: "refund", idempotency_key: "guard-#{user.id}")
    Order.create!(user: user, prize_key: "sticker_pack", prize_name: "Sticker pack", coins: 20, kind: "purchase", idempotency_key: "guard-#{user.id}")
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
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: user.hca_uid)

    deleted = Privacy::Deleter.new(subject).call(dry_run: true).deleted

    # Tables that reference users directly, plus the ones that only reach a user through a project.
    referencing = app_tables.select { |table| user_foreign_keys(table).any? }
    through_projects = %w[link_suggestions]
    assert_equal (referencing + through_projects + [ "users" ]).sort, deleted.keys.sort,
                 "add a row for the new table to this test so its count is proven (every table that references users must show up)"
  end
end
