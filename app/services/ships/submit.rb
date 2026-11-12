module Ships
  # Creates (or updates) a project's ship and, when asked, submits it. Everything happens under the owner's and the
  # project's row locks, so two quick clicks, two tabs or two projects cannot open two ships or double-count a window.
  #
  # The hours window is read again under the lock and written onto the ship (`coded_seconds`, the dates, the
  # seconds per date, the Hackatime project names it covers): that snapshot is what staff review and what pays out,
  # and the names keep those hours covered wherever the links move later. Hours coded afterwards go to the next
  # ship. Raises a Ships::Submit::Refused subclass when the project cannot be shipped right now; otherwise returns the
  # ship (saved, or unsaved with errors when the form was not valid).
  #
  #   Ships::Submit.call(project: project, attributes: { description:, repo_url:, demo_url: }, submit: true)
  #   Ships::Submit.call(project: project, ship: draft, attributes: {...}, submit: true)   # continue a draft
  #
  # Emits `ship_submitted.battletown` (ship_id only) after the ship is saved as submitted.
  class Submit
    class Refused < StandardError; end
    class NoHackatimeLink < Refused; end
    class NoHours < Refused; end
    class TooFewHours < Refused; end
    class AlreadyOpen < Refused
      attr_reader :ship

      def initialize(ship)
        @ship = ship
        super("this project already has an open ship")
      end
    end
    class NotEditable < Refused; end

    def self.call(**args) = new(**args).call

    # `after_save` (optional) is called with the ship inside the same transaction once it has been saved (the screenshots
    # of the flagged `ship_screenshots` feature use it, so the ship and its images are saved together or not at all).
    def initialize(project:, attributes:, submit:, ship: nil, config: Config.current, now: Time.current, after_save: nil)
      @after_save = after_save
      @project = project
      @attributes = attributes
      @submit = submit
      @ship = ship
      @config = config
      @now = now
    end

    def call
      saved = nil
      Ship.transaction do
        # The owner's row first: coverage is per Hackatime project across all their projects, so two of their
        # projects must not read the same uncovered hours at once (a link can move between them meanwhile).
        User.lock.find(@project.user_id)
        @project.lock!
        ship = prepare_ship
        window = Window.call(@project)
        check_window!(window)
        apply(ship, window)
        saved = ship.save
        @after_save&.call(ship) if saved
        @ship = ship
      end
      instrument if saved && @submit
      @ship
    rescue ActiveRecord::RecordNotUnique
      raise AlreadyOpen, @project.ships.open_now.first
    end

    private

    def prepare_ship
      open = @project.ships.open_now.first
      if @ship
        raise NotEditable, "only a draft can be changed" unless open == @ship && open.status_draft?

        open
      else
        raise AlreadyOpen, open if open

        @project.ships.build(user: @project.user)
      end
    end

    def check_window!(window)
      raise NoHackatimeLink, "link a Hackatime project first" unless @project.hackatime_links.exists?
      raise NoHours, "no coded time since the last ship" if window.empty?
      raise TooFewHours, "not enough coded time yet" if @submit && window.seconds < @config.min_seconds
    end

    def apply(ship, window)
      ship.assign_attributes(@attributes)
      ship.assign_attributes(coded_seconds: window.seconds, window_start_date: window.start_date, window_end_date: window.end_date,
                             daily_seconds: window.seconds_by_date.transform_keys(&:iso8601), hackatime_projects: window.hackatime_projects)
      return ship.status = "draft" unless @submit

      ship.status = "submitted"
      ship.submitted_at = @now
    end

    def instrument
      ActiveSupport::Notifications.instrument("ship_submitted.battletown", ship_id: @ship.id)
    end
  end
end
