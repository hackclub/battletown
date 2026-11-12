module Ships
  # Staff approval of a submitted ship, in ONE transaction under the user's and then the ship's row lock: the status is
  # checked again, the ship becomes approved and Coins::ApproveShip credits the user (base coins plus streak bonus
  # coins). The credit is idempotent by the ship reference, and a second approver (or a double click) finds the ship already
  # approved and does nothing, so one ship never pays twice. If anything fails, the status change and the credit
  # roll back together.
  #
  # `approved_seconds` can only be lowered from what was coded and must be a whole number of config steps (0.25 h)
  # unless it is exactly the coded time. Streak days still inside the settling grace period earn no bonus yet:
  # `unsettled_dates` lists them (before approving, with `.unsettled_dates(ship)`, and afterwards in the Result) and
  # a note is kept on the ship (`payout_note`). Settling happens first, with the real hours source, outside the
  # locks; the payout itself is spread over the ship's own snapshot (Ships::SnapshotSource).
  #
  # Staff can never approve their own ship (`OwnShip`, a kind of Invalid, so the friendly message reaches the admin).
  #
  # Emits `ship_approved.battletown` (ship_id only) after the transaction commits.
  module Approve
    class Invalid < ArgumentError; end

    OWN_SHIP_MESSAGE = "You can't review your own ship. Ask another reviewer.".freeze
    class OwnShip < Invalid
      def initialize(message = OWN_SHIP_MESSAGE) = super
    end

    Result = Data.define(:status, :ship, :unsettled_dates, :credit) do
      def approved? = status == :approved
      def unavailable? = status == :unavailable
    end

    module_function

    # Result#status is :approved (done now) or :unavailable (not waiting for review any more: nothing was changed).
    def call(ship:, reviewer:, approved_seconds:, now: Time.current, config: Config.current)
      raise OwnShip if ship.user_id == reviewer&.id

      seconds = validate!(ship, approved_seconds, config)
      Game::Settle.call(ship.user, through: now)

      result = nil
      # Lock order: the user's row, then the ship's. Ships::Submit and Project#discard! hold the user and then write
      # ship rows, so taking the ship first here could deadlock with them (docs/CONTRACT.md, "Row lock order").
      ship.user.with_lock do
        ship.lock!
        next result = Result.new(status: :unavailable, ship: ship, unsettled_dates: [], credit: nil) unless ship.status_submitted?

        credit = Coins::ApproveShip.call(user: ship.user, ship_reference: ship, approved_seconds: seconds, window_dates: ship.window_dates,
                                         hours_since_previous_ship_before_window: 0, source: SnapshotSource.new(ship), now: now)
        note = payout_note(credit.unsettled_dates)
        ship.update!(status: "approved", approved_seconds: seconds, reviewer: reviewer, reviewed_at: now, payout_note: note)
        result = Result.new(status: :approved, ship: ship, unsettled_dates: credit.unsettled_dates, credit: credit)
      end
      ActiveSupport::Notifications.instrument("ship_approved.battletown", ship_id: ship.id) if result.approved?
      result
    end

    # The ship's window dates whose streak day is not final yet (no bonus for them if approved now), as ApproveShip counts them:
    # a date is final once it has a daily_results row, or once its clock has run out (approving settles it first). The row
    # matters after a move west, when the new zone's clock has not reached a date that already settled.
    def unsettled_dates(ship, now: Time.current)
      zone = Game::Days.zone(ship.user.time_zone)
      first_counted = Hours::Days.first_counted_date(ship.user)
      dates = ship.window_dates
      settled = DailyResult.where(user_id: ship.user_id, local_date: dates).pluck(:local_date).to_set
      dates.reject { |date| date < first_counted || settled.include?(date) || Game::Days.settled?(date, zone, now) }
    end

    # Hours text from the form ("1.25") to whole seconds, or the coded time when blank. Raises Invalid with a friendly message.
    def seconds_from_hours(ship, text)
      return ship.coded_seconds if text.to_s.strip.empty?

      # A plain decimal only: BigDecimal would happily expand "1e100000000" (tens of seconds of CPU) before any bound is checked.
      raise ArgumentError unless text.to_s.strip.match?(/\A\d{1,6}(?:\.\d{1,6})?\z/)

      hours = BigDecimal(text.to_s.strip)
      seconds = (hours * 3600)
      raise Invalid, "Approved hours must be a number such as 1.5." unless seconds.frac.zero?

      seconds.to_i
    rescue ArgumentError
      raise Invalid, "Approved hours must be a number such as 1.5."
    end

    def validate!(ship, seconds, config)
      raise Invalid, "Approved hours must be a whole number of seconds." unless seconds.is_a?(Integer)
      raise Invalid, "Approve at least one step (#{step_text(config)} hours), or reject the ship." unless seconds.positive?
      raise Invalid, "You can approve up to the #{hours_text(ship.coded_seconds)} hours coded, not more." if seconds > ship.coded_seconds
      raise Invalid, "Approved hours go in steps of #{step_text(config)} (or all of the coded time)." unless seconds == ship.coded_seconds || (seconds % config.step_seconds).zero?

      seconds
    end

    def payout_note(dates)
      return if dates.empty?

      "Bonus coins for #{dates.size} recent #{'day'.pluralize(dates.size)} (#{dates.map(&:iso8601).join(', ')}) were not included: those days were not final yet when this was approved.".truncate(Ship::NOTE_MAX)
    end

    def step_text(config) = format("%g", config.step_seconds / 3600.0)

    def hours_text(seconds) = format("%.2f", seconds / 3600.0).sub(/\.?0+\z/, "")

    private_class_method :validate!, :payout_note, :step_text, :hours_text
  end
end
