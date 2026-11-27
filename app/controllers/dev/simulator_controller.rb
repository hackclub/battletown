# Development-only JSON endpoints behind the event simulator panel on the dashboard (app/views/dashboard/_simulator.html.erb):
# make simulated players, make them ship, remove them, and read the numbers back. The simulator writes to the dev database, so
# it also refuses unless that database is on this machine (DevSimulator.check_local_database!). Outside development every request
# is a 404 (same as an unknown path), signed-out visitors are sent to sign in, and the writes are CSRF-protected like any other
# POST (the panel sends the page's token). Never reachable in test or production.
module Dev
  class SimulatorController < ApplicationController
    before_action :require_development!
    before_action :require_login

    rescue_from DevSimulator::Refused do |error|
      render json: { error: error.message }, status: :unprocessable_content
    end

    # (Not named `status`: that is the response status on every controller.)
    def numbers
      render json: { status: DevSimulator::Status.call(user: current_user, today: today) }
    end

    def create_players
      result = DevSimulator::Players.call(count: params[:count], today: today)
      message = if result.created.zero? && result.credited.zero?
        "Nothing changed: those #{result.existing} players are already there and have coded today. #{result.total} players in all."
      else
        "#{result.created} created, #{result.existing} already there, #{result.credited} coded today. #{result.total} players in all."
      end
      respond_with_status(message, result)
    end

    def ship
      state = presenter_state
      result = DevSimulator::Ship.call(mode: params[:mode].to_s, percent: params.fetch(:percent, 30), count: params.fetch(:count, 3), today: today,
                                       hours_min: params.fetch(:hours_min, DevSimulator::DEFAULT_HOURS_MIN), hours_max: params.fetch(:hours_max, DevSimulator::DEFAULT_HOURS_MAX))
      # Only a boss still in the fight takes damage; `hit_seconds` is what the panel floats up from the boss.
      hit = state == :in_progress ? result.seconds : 0
      respond_with_status(ship_message(result, state), result, hit_seconds: hit)
    end

    def reset
      result = DevSimulator::Reset.call(today: today, clear_defeat: params[:clear_defeat].to_s == "true")
      message = if result.removed.zero? && result.cleared_defeat.zero?
        "Nothing to remove: there are no simulated players."
      else
        "Removed #{result.removed} simulated players#{' and cleared the boss defeat' if result.cleared_defeat.positive?}."
      end
      respond_with_status(message, result)
    end

    private

    # The UTC date, not the developer's local one: the boss week is cut by the UTC date of a ship (Bosses::Damage), so the panel's
    # boss lookups, the players' coding day and the card all have to name the same day.
    def today = Hours::Days.today("UTC")

    # One answer for every action: a sentence for the panel, the counts of what just ran and the numbers to redraw the page with.
    def respond_with_status(message, result, **extra)
      render json: { message: message, status: DevSimulator::Status.call(user: current_user, today: today, last: result.to_h.merge(extra)) }
    end

    # :none, :in_progress, :defeated or :escaped: the boss as the dashboard card sees it right now.
    def presenter_state = Bosses::Presenter.new(user: current_user, today: today).state

    # Says plainly what a ship did to the boss, and why not when it did nothing.
    def ship_message(result, state)
      hours = (result.seconds / 3600.0).round(1)
      return "Nobody shipped#{skipped_words(result.skipped)}. The boss took no damage." if result.shipped.zero?

      shipped = "#{result.shipped} of #{result.players} shipped#{skipped_words(result.skipped)}"
      case state
      when :in_progress then "#{shipped}. #{hours} hours hit the boss.#{' The boss is defeated!' if presenter_state == :defeated}"
      when :defeated then "#{shipped}, but the boss is already defeated, so the bar cannot move. Remove players with 'let this week's boss fall again' ticked to fight it again."
      when :escaped then "#{shipped}, but the boss got away this week, so the bar cannot move."
      else "#{shipped}, but there is no boss this week to hit."
      end
    end

    def skipped_words(skipped)
      return "" if skipped.empty?

      " (skipped #{skipped.map { |reason, count| "#{count} #{reason.to_s.tr('_', ' ')}" }.join(', ')})"
    end

    def require_development!
      raise ActionController::RoutingError, "Not Found" unless Rails.env.development?
    end
  end
end
