module Dashboard
  # What the top of the dashboard says to do next: one headline (said in words for assistive tech) and the ship button's state.
  # The numbers come from the game config and the active project, nothing here is stored:
  #
  #   * Before the commit mark (half of the daily goal) it is the coding time until the next commit.
  #   * After it, it is the project's coding time since its last ship toward the minimum to ship.
  #   * A project that can ship says so: the ship button is the whole message.
  #
  # "Commit" is a pacing mark for now (a nudge to save your work about every half goal); it is not checked against GitHub.
  # The goal bar's ticks (`ticks`) sit at the quick mark, the commit mark and the goal, which is where the player ships.
  class Stage
    Tick = Data.define(:key, :percent, :label)

    # `cta` is :ship, :continue, :view, :add_project, :link, or :wait (not ready: a disabled button).
    View = Data.define(:phase, :headline, :cta, :cta_label, :reason, :ticks)

    def self.for(presenter) = new(presenter).view

    def initialize(presenter)
      @presenter = presenter
    end

    def view
      View.new(phase: phase, headline: headline, cta: cta, cta_label: cta_label, reason: reason, ticks: ticks)
    end

    private

    attr_reader :presenter

    def today = presenter.today

    def project = presenter.project

    def config = Game::Config.current

    def commit_seconds = config.goal_seconds / 2

    def seconds = today.seconds

    def phase
      return :ship if project&.can_ship
      return :commit if seconds < commit_seconds

      :ship_prep
    end

    # A full stop, unless the text already ends in the ellipsis of a project name cut short ("A tool that automates…").
    def sentence(text) = text.end_with?("…") ? text : "#{text}."

    def to_go(remaining) = Dashboard::Presenter.minutes_text([ (remaining / 60.0).ceil, 1 ].max)

    def headline
      case phase
      when :ship then sentence("You have enough coding time to ship #{project.name}")
      when :commit then "You have about #{to_go(commit_seconds - seconds)} until your next commit. What are you going to do?"
      else prep_headline
      end
    end

    def prep_headline
      return "Add a project, then ship it." unless project

      case project.readiness
      when :no_link then "Link Hackatime to count toward a ship."
      when :no_hours then sentence("Code on #{project.name} to start toward your next ship")
      when :ship_open then "Your ship is in. Nice work."
      else "About #{to_go(ship_remaining)} until you can ship."
      end
    end

    def ship_remaining = [ Ships::Config.current.min_seconds - project.window_seconds, 0 ].max

    def cta
      return :add_project unless project
      return :ship if project.can_ship

      case project.readiness
      when :ship_open then project.ship&.status == "draft" ? :continue : :view
      when :no_link then :link
      else :wait
      end
    end

    def cta_label
      case cta
      when :ship then "Ship #{project.name}"
      when :continue then "Continue your draft"
      when :view then "View your ship"
      when :add_project then "Add a project"
      when :link then "Link a Hackatime project"
      else "Ship"
      end
    end

    # Said under the button when it is not a live ship button, so a disabled button always explains itself. Short on purpose.
    def reason
      return unless project

      case project.readiness
      when :no_link then "Link Hackatime to start counting."
      when :no_hours then "No coding on this project yet."
      when :too_few then "#{Dashboard::Presenter.minutes_text((ship_remaining / 60.0).ceil)} of coding to go."
      end
    end

    def ticks
      goal = config.goal_seconds
      quick = config.quick_seconds
      [
        Tick.new(key: :quick, percent: percent(quick, goal), label: "#{quick / 60} min"),
        Tick.new(key: :commit, percent: percent(commit_seconds, goal), label: "#{commit_seconds / 60} min, commit"),
        Tick.new(key: :ship, percent: 100.0, label: "#{goal / 60} min, ship")
      ]
    end

    def percent(part, whole) = (part * 100.0 / whole).round(2)
  end
end
