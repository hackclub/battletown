module Bosses
  # Everything the boss card shows, as plain values (no ActiveRecord objects leak into the view).
  #
  #   presenter = Bosses::Presenter.new(user: current_user)           # "today" is the user's own local date
  #   presenter = Bosses::Presenter.new(user: current_user, today: Date.new(2026, 11, 16))
  #   render "bosses/card", presenter: presenter
  #
  # States:
  #   :in_progress  a boss whose week covers the user's local today, still standing
  #   :defeated     that boss is down (set once by Bosses::CheckDefeat; kept for the rest of the week), or a boss that
  #                 ended within `afterglow_days` and fell
  #   :escaped      a boss that ended within `afterglow_days` and was not beaten. No penalty
  #   :none         before the first boss, between bosses, after the last
  #
  # Only aggregates about the community are ever exposed (how many people coded today), plus the CURRENT user's own
  # total. Nobody else's name, avatar, id or damage is read, let alone shown.
  class Presenter
    # Facts the presenter works from. `boss` is nil for :none; `damage` is the community total in seconds.
    Facts = Data.define(:today, :boss, :damage, :user_seconds, :active_today, :upcoming_on, :previous_escaped_name)

    # How long after a boss starts a gentle "last week's boss got away" note is shown on the new boss's card.
    PREVIOUS_NOTE_DAYS = 3

    # A card for a made-up boss in a chosen state, for the development page. Nothing is read or written.
    def self.preview(state:, health_percent: 62, today: Date.current)
      hp = 500 * 3600
      boss = Boss.new(name: "Preview boss", art_key: "placeholder", hp_seconds: hp)
      damage = hp - (hp * health_percent.clamp(0, 100) / 100)
      case state.to_sym
      when :in_progress
        boss.assign_attributes(starts_on: today - 2, ends_on: today + 4)
      when :defeated
        boss.assign_attributes(starts_on: today - 2, ends_on: today + 4, defeated_at: Time.current)
        damage = hp + (2 * 3600) + (13 * 60)
      when :escaped
        boss.assign_attributes(starts_on: today - 8, ends_on: today - 1)
      else
        boss = nil
        damage = 0
      end
      new(facts: Facts.new(today: today, boss: boss, damage: damage, user_seconds: (2 * 3600) + (35 * 60),
                           active_today: 12, upcoming_on: (today.next_occurring(:friday) if boss.nil?), previous_escaped_name: nil))
    end

    def self.human_duration(seconds)
      hours, rest = seconds.divmod(3600)
      minutes = rest / 60
      return "less than a minute" if hours.zero? && minutes.zero?

      [ (pluralize(hours, "hour") if hours.positive?), (pluralize(minutes, "minute") if minutes.positive?) ].compact.join(" ")
    end

    def self.pluralize(count, word) = "#{count} #{word}#{'s' unless count == 1}"

    def initialize(user: nil, today: nil, facts: nil)
      @facts = facts || gather(user, today || Hours::Days.today(user))
    end

    def state
      @state ||= if boss.nil? then :none
      elsif defeated? then :defeated
      elsif week_over? then :escaped
      else :in_progress
      end
    end

    def boss? = !boss.nil?

    def boss_name = boss&.name

    def art_path = boss&.art_path

    def art_alt = boss && Boss::ARTS.fetch(boss.art_key)

    # Percent of the health that has been dealt (integer floor, 0 to 100) and the same as a fraction.
    def damage_percent = boss ? BossMath.percent(damage, boss.hp_seconds) : 0

    def damage_ratio = boss ? BossMath.ratio(damage, boss.hp_seconds) : 0.0

    # Percent of the health still standing (what the bar shows). A fallen boss is 0 even if a later correction
    # lowered the damage; a boss that is not down never shows 0.
    def health_percent = defeated? ? 0 : 100 - damage_percent

    def health_ratio = defeated? ? 0.0 : 1.0 - damage_ratio

    def remaining_seconds = defeated? || boss.nil? ? 0 : BossMath.remaining(damage, boss.hp_seconds)

    # "about 190 hours to go": whole hours, truncated (never rounded up), so a boss is never "closer" than it is.
    def hours_to_go_text
      return unless boss? && remaining_seconds.positive?

      hours = remaining_seconds / 3600
      hours.zero? ? "less than an hour to go" : "about #{self.class.pluralize(hours, 'hour')} to go"
    end

    def overkill_seconds = boss ? BossMath.overkill(damage, boss.hp_seconds) : 0

    def overkill_text = (self.class.human_duration(overkill_seconds) if overkill_seconds.positive?)

    # Calendar days left in the boss week including today (1 on the last day); 0 once it is over or when none.
    def days_left = in_week? ? (boss.ends_on - today).to_i + 1 : 0

    def ends_on = boss&.ends_on

    def end_day_name = ends_on&.strftime("%A")

    def days_left_text
      case days_left
      when 0 then nil
      when 1 then "Last day, make it count"
      else "#{days_left} days left, ends #{end_day_name}"
      end
    end

    # The sentence a screen reader (and everyone else) gets with the bar.
    def summary
      case state
      when :in_progress
        [ "Boss at #{health_percent}% health, #{hours_to_go_text}.", ("Ends #{days_left == 1 ? 'today' : end_day_name}." if days_left.positive?) ].compact.join(" ")
      when :defeated then [ "Boss defeated.", ("Overkill: #{overkill_text}." if overkill_text) ].compact.join(" ")
      when :escaped then "Boss escaped with #{health_percent}% health left, #{hours_to_go_text}."
      else "No boss right now."
      end
    end

    # Own contribution only: the current user's raw coded seconds in the boss week (0 when there is none).
    def contributed_seconds_this_week = @facts.user_seconds

    def contributed_text
      return unless boss?

      seconds = contributed_seconds_this_week
      if seconds.positive?
        "#{week_over? ? "You dealt" : "You've dealt"} #{self.class.human_duration(seconds)} of damage#{' this week' unless week_over?}."
      elsif state == :in_progress || (state == :defeated && !week_over?)
        "Code for 15 minutes to land your first hit."
      end
    end

    # Whether the user coded enough in the boss week to wear the Boss slayer badge. Only when the boss fell.
    def user_slayer? = state == :defeated && contributed_seconds_this_week >= Config.current.slayer_seconds

    # The boss is down, the user has not earned the badge yet and the week is still on: they can still get it.
    def slayer_still_possible? = state == :defeated && !user_slayer? && in_week?

    # How many people coded at least 15 minutes on the user's local today. A count, never a list.
    def community_active_today = @facts.active_today

    def community_text
      count = community_active_today
      return "Be the first to code today." if count.zero?

      count == 1 ? "1 person coded today." : "#{count} people coded today."
    end

    # In :none, when the next boss arrives (a Date) if one is scheduled.
    def upcoming_on = @facts.upcoming_on

    def upcoming_text = (upcoming_on && "The next boss arrives #{upcoming_on.strftime('%A %-d %B')}.")

    # The boss that just ended without falling, while this week's boss is new (nil otherwise).
    def previous_escaped_name = @facts.previous_escaped_name

    private

    def boss = @facts.boss

    def damage = @facts.damage

    def today = @facts.today

    def defeated? = boss.present? && (boss.defeated_at.present? || BossMath.defeated?(damage, boss.hp_seconds))

    def in_week? = boss.present? && boss.starts_on <= today && today <= boss.ends_on

    def week_over? = boss.present? && today > boss.ends_on

    def gather(user, today)
      boss = Boss.covering(today).first
      boss ||= Boss.where(ends_on: (today - Config.current.afterglow_days)...today).order(ends_on: :desc).first
      return empty_facts(today) unless boss

      Facts.new(today: today, boss: boss, damage: Damage.for(boss),
                user_seconds: Hours::Totals.seconds_by_date(user, boss.range).values.sum,
                active_today: Hours::Totals.active_user_count(today), upcoming_on: nil,
                previous_escaped_name: previous_escaped_name_for(boss, today))
    end

    def empty_facts(today)
      Facts.new(today: today, boss: nil, damage: 0, user_seconds: 0, active_today: Hours::Totals.active_user_count(today),
                upcoming_on: Boss.where(starts_on: (today + 1)..).minimum(:starts_on), previous_escaped_name: nil)
    end

    def previous_escaped_name_for(boss, today)
      return unless today >= boss.starts_on && today < boss.starts_on + PREVIOUS_NOTE_DAYS

      previous = Boss.find_by(ends_on: boss.starts_on - 1)
      previous.name if previous && previous.defeated_at.nil? && !BossMath.defeated?(Damage.for(previous), previous.hp_seconds)
    end
  end
end
