module Admin
  # The staff queue of weekly merch-track claims (flag `merch_track`): requested first, filter by status, mark fulfilled,
  # cancel. Shows the person's display name, Slack id and verification status (staff need them to arrange delivery over
  # Slack); no address exists anywhere in this app. No coins are involved, so nothing is refunded.
  class MerchClaimsController < BaseController
    LIMIT = 200

    before_action { require_feature!(:merch_track) }
    before_action :set_claim, only: %i[fulfill cancel]

    def index
      @status = MerchClaim::STATUSES.include?(params[:status]) ? params[:status] : nil
      scope = MerchClaim.includes(:user, :boss).queue_order
      scope = scope.where(status: @status) if @status
      @claims = scope.limit(LIMIT).to_a
      @requested_count = MerchClaim.where(status: "requested").count
    end

    def fulfill
      MerchTrack::Fulfill.call(claim: @claim, by: current_user)
      redirect_to back_path, notice: "Marked #{@claim.item_name} fulfilled."
    rescue MerchTrack::Error => error
      redirect_to back_path, alert: error.message
    end

    def cancel
      MerchTrack::Cancel.call(claim: @claim, by: current_user)
      redirect_to back_path, notice: "Cancelled #{@claim.item_name}."
    rescue MerchTrack::Error => error
      redirect_to back_path, alert: error.message
    end

    private

    def set_claim = @claim = MerchClaim.find(params[:id])

    # Keep the filter the staff member was looking at.
    def back_path = admin_merch_claims_path(status: (params[:status] if MerchClaim::STATUSES.include?(params[:status])))
  end
end
