module MerchTrack
  # Staff marks a requested claim fulfilled (the team has arranged delivery). Idempotent: a claim that is already
  # fulfilled is returned unchanged and keeps its original fulfilled_at. A cancelled claim cannot be fulfilled.
  class Fulfill
    def self.call(...) = new(...).call

    def initialize(claim:, by:)
      @claim = claim
      @by = by
    end

    def call
      raise Unavailable unless Features.enabled?(:merch_track)
      raise NotFulfillable, "Only an admin can mark a claim fulfilled." unless @by&.admin?

      User.find(@claim.user_id).with_lock do
        @claim.lock!
        next @claim if @claim.fulfilled?

        raise NotFulfillable, "A cancelled claim can't be fulfilled." unless @claim.requested?

        @claim.update!(status: "fulfilled", fulfilled_at: Time.current)
        @claim
      end
    end
  end
end
