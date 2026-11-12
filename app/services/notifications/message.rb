module Notifications
  # Builds the text of one outbox row at send time (nothing is stored). Returns nil when the thing the message is
  # about is gone or no longer true (a suggestion already answered, a project that was shipped in the meantime, a ship
  # that is not in the expected state): the dispatcher then cancels the row instead of sending stale news.
  #
  # Templates live in config/notifications.yml with {placeholders}. Values are one line, shortened and escaped for
  # Slack (& < >), so a project name or a reviewer's note can never open a mention or a link.
  module Message
    REASON_MAX = 140
    NAME_MAX = 60
    PLACEHOLDER = /\{(\w+)\}/

    module_function

    def build(row, user, config: Config.current)
      values = values_for(row, user)
      return nil if values.nil?

      render(config.template(row.kind), values)
    end

    def render(template, values)
      template.gsub(PLACEHOLDER) { slack_escape(values.fetch(Regexp.last_match(1).to_sym, "").to_s) }
    end

    # nil means "do not send".
    def values_for(row, user)
      case row.kind
      when "daily_reminder" then {}
      when "link_question" then link_question(row, user)
      when "ship_reminder", "ship_mvp" then ship_reminder(row, user)
      when "ship_approved" then ship_approved(row, user)
      when "ship_rejected" then ship_rejected(row, user)
      when "nps_prompt" then nps_prompt(row, user)
      when "returning_nudge" then returning_nudge(row, user)
      end
    end

    # The survey link: a fresh signed token (so it lasts `nps.token_ttl_days` from now). Nothing is sent when the flag is
    # off, or when the person already answered for this window or since.
    def nps_prompt(row, user)
      window = Nps::Eligibility.window_date(row.subject_id)
      return nil unless window && Features.enabled?(:nps)
      return nil if NpsResponse.where(user_id: user.id).where("prompt_window_date >= ?", window).exists?

      { link: Links.feedback(Nps::Token.generate(user, window)) }
    end

    def link_question(row, user)
      suggestion = LinkSuggestion.pending.find_by(id: row.subject_id)
      project = suggestion && user.projects.find_by(id: suggestion.project_id)
      return nil unless project

      { project: short(project.name), hackatime_project: short(suggestion.hackatime_project), link: Links.projects }
    end

    def ship_reminder(row, user)
      project = user.projects.live.find_by(id: row.subject_id)
      threshold = ShipReminders.threshold_seconds(row.kind)
      return nil unless project && Ships::Window.call(project).seconds >= threshold

      { project: short(project.name), hours: hours_text(threshold), link: Links.ship_form(project.id) }
    end

    def ship_approved(row, user)
      ship = user.ships.find_by(id: row.subject_id, status: "approved")
      return nil unless ship

      { project: short(ship.project.name), hours: hours_text(ship.approved_seconds), coins: ship.coin_breakdown[:total],
        unlock_note: unlock_note(user), link: Links.ship(ship) }
    end

    def ship_rejected(row, user)
      ship = user.ships.find_by(id: row.subject_id, status: "rejected")
      return nil unless ship

      { project: short(ship.project.name), reason: sentence(ship.rejection_reason), link: Links.fix_ship(ship) }
    end

    # Only while the `returning` flag is on, only while the idle period it was queued for is still the current one, and
    # not once the person has coded today (they are already back).
    def returning_nudge(row, user)
      return nil unless Features.enabled?(:returning)

      last_on = ReturningNudges.last_active_on(user)
      return nil unless last_on && ReturningNudges.subject_for(last_on) == row.subject_id
      return nil if ReturningNudges.back_today?(user, Time.current)

      { boost_days: Game::ReturningBoost.config.boost_days, link: Links.dashboard }
    end

    def unlock_note(user)
      case user.spend_state
      when :ready then ""
      when :not_eligible then " Your coins are saved, but prizes are only available to people who qualify for Hack Club YSWS programs. #{Eligibility::Config.current.help_line}"
      when :stale then " #{Shop::NeedsRecheck::TEXT} Your coins are saved and you keep earning."
      else " Your coins unlock when you verify your identity with Hack Club (#{ShopHelper::VERIFY_URL}). You keep earning in the meantime."
      end
    end

    # 5, 2.5 (never 5.0).
    def hours_text(seconds)
      hours = (seconds / 3600.0).round(1)
      hours == hours.to_i ? hours.to_i.to_s : hours.to_s
    end

    def short(text) = text.to_s.squish.truncate(NAME_MAX)

    def sentence(text)
      line = text.to_s.squish.truncate(REASON_MAX)
      line.match?(/[.!?]\z/) ? line : "#{line}."
    end

    def slack_escape(text) = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end
end
