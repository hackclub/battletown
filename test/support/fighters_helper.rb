require_relative "bosses_helper"

# Builders for the boss stage's fighters (Bosses::Fighters). Time is fixed: a Wednesday inside the boss week FRIDAY..THURSDAY.
module FightersHelper
  include BossesHelper

  NOW = Time.utc(2026, 11, 18, 12)

  # Coded time that reached the ledger `ago` before `now`, dated the UTC day it was recorded (or `date`), the way Hours::Credit writes it.
  def code_ago(user, seconds, ago: 1.hour, now: NOW, date: nil, project: nil, source: "manual")
    at = now - ago
    HourEntry.create!(user: user, local_date: date || at.utc.to_date, seconds: seconds, source: source, note: "test", hackatime_project: project,
                      idempotency_key: SecureRandom.hex(8), recorded_at: at)
  end

  # A person who has coded `seconds` in the last day (and, with a name, chosen a display name).
  def fighter(key, seconds: 1800, name: nil, ago: 1.hour, now: NOW)
    user = User.create!(hca_uid: "ident!#{key}", email: "#{key}@private.example.org", display_name: "Real Name #{key}", slack_id: "U#{key.upcase}SLK",
                        created_at: Time.utc(2026, 9, 14), signed_up_on: Date.new(2026, 9, 14), time_zone: "UTC", onboarded_at: Time.utc(2026, 9, 14),
                        onboarding_step: 6, prize_key: "tshirt", project_kind: "game", coding_days: 5, coding_time: "18:30", profile_name: name)
    code_ago(user, seconds, ago: ago, now: now) if seconds
    user
  end

  def fighters_at(boss, now: NOW) = Bosses::Fighters.call(boss, now: now)

  def swap_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end
end
