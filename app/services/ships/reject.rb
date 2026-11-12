module Ships
  # Staff rejection of a submitted ship, under `ship.with_lock` with the status checked again. The reason (a preset
  # and/or free text, at most 300 characters in all) is shown to the teen. The window is not consumed: a rejected
  # ship's hours are free again, so the project can be fixed and shipped as a NEW ship for the same window.
  # Emits `ship_rejected.battletown` (ship_id only) after the change is saved.
  module Reject
    class Invalid < ArgumentError; end

    Result = Data.define(:status, :ship) do
      def rejected? = status == :rejected
    end

    module_function

    # Joins a preset and extra text into the stored reason; raises Invalid when empty or longer than 300 characters.
    def reason_from(preset:, note:, config: Config.current)
      preset = preset.to_s.squish
      preset = "" unless config.rejection_reasons.include?(preset)
      reason = [ preset.presence, note.to_s.squish.presence ].compact.join(": ")
      raise Invalid, "Give a reason: pick one or write a few words." if reason.empty?
      raise Invalid, "The reason can be up to #{Ship::REASON_MAX} characters (this one is #{reason.length})." if reason.length > Ship::REASON_MAX

      reason
    end

    def call(ship:, reviewer:, reason:, now: Time.current)
      result = nil
      ship.with_lock do
        next result = Result.new(status: :unavailable, ship: ship) unless ship.status_submitted?

        ship.update!(status: "rejected", rejection_reason: reason, reviewer: reviewer, reviewed_at: now)
        result = Result.new(status: :rejected, ship: ship)
      end
      ActiveSupport::Notifications.instrument("ship_rejected.battletown", ship_id: ship.id) if result.rejected?
      result
    end
  end
end
