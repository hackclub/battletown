module MerchTrack
  # Staff cancels a requested claim. There is nothing to refund (no coins are involved). Idempotent: a claim that is
  # already cancelled is returned unchanged. A fulfilled claim cannot be cancelled. The week stays claimed (one claim
  # per person per week), so a cancelled claim is a staff decision to talk through on Slack, not a way to claim twice.
  class Cancel
    def self.call(...) = new(...).call

    def initialize(claim:, by:)
      @claim = claim
      @by = by
    end

    def call
      raise Unavailable unless Features.enabled?(:merch_track)
      raise NotCancellable, "Only an admin can cancel a claim." unless @by&.admin?

      User.find(@claim.user_id).with_lock do
        @claim.lock!
        next @claim if @claim.cancelled?

        raise NotCancellable unless @claim.requested?

        @claim.update!(status: "cancelled", cancelled_at: Time.current)
        @claim
      end
    end
  end
end
