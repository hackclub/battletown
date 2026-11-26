require_relative "bosses_helper"

# Builders and a sign-in for the profile and settings tests.
module ProfilesHelper
  include BossesHelper

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(provider: "hack_club", uid: user.hca_uid, extra: { raw_info: {} })
    post "/auth/hack_club"
    follow_redirect!
  end

  def reset_omniauth
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hack_club] = nil
  end

  # An onboarded player with real-looking private details (so a leak is easy to spot). Every player has a profile; `name` is the display
  # name they chose (without one they are shown by a generated handle, or their Slack name).
  def make_player(key, name: nil, display_name: "Ada Lovelace #{key}")
    User.create!(hca_uid: "ident!#{key}", email: "#{key}@private.example.org", display_name: display_name, slack_id: "U#{key.upcase}SLK",
                        created_at: Time.utc(2026, 9, 14), signed_up_on: Date.new(2026, 9, 14), time_zone: "UTC", onboarded_at: Time.utc(2026, 9, 14),
                        onboarding_step: 6, prize_key: "tshirt", project_kind: "game", coding_days: 5, coding_time: "18:30", profile_name: name)
  end

  # A live project for the user with an optional handed-in (submitted) ship.
  def make_project(user, name, kind: "game", **attrs)
    Project.create!({ user: user, name: name, kind: kind, active: false }.merge(attrs))
  end

  def ship_for(project, seconds: 3600, on: FRIDAY, status: "submitted")
    at = on.is_a?(Date) ? on.in_time_zone("UTC").change(hour: 12) : on
    day = at.utc.to_date
    attrs = { user: project.user, project: project, status: status, description: "Hit the boss.", repo_url: "https://github.com/octo/boss-hit",
              coded_seconds: seconds, window_start_date: day, window_end_date: day, daily_seconds: { day.iso8601 => seconds } }
    attrs[:submitted_at] = at unless status == "draft"
    attrs.merge!(approved_seconds: seconds, reviewed_at: at) if status == "approved"
    attrs.merge!(rejection_reason: "Not yet", reviewed_at: at) if status == "rejected"
    Ship.create!(attrs)
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
