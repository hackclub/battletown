module Admin
  # /admin/nps (flag `nps`): the survey results for staff. The page shows aggregate numbers and the recent comments WITHOUT
  # who wrote them, because a free-text comment can identify a teen. Seeing the author is a separate, explicit action
  # (POST reveal) that is written to the staff audit trail first (AdminAudit: who and which row, no content, no name).
  class NpsController < BaseController
    COMMENTS_SHOWN = 30

    def index
      @overall = Nps::Stats.overall
      @trend = Nps::Stats.trend
      @comments = NpsResponse.with_comment.newest_first.limit(COMMENTS_SHOWN).select(:id, :score, :comment, :answered_at)
      @retention_days = Nps::Config.current.comment_retention_days
    end

    def reveal
      @answer = NpsResponse.with_comment.find_by(id: params[:id]) or not_found
      AdminAudit.record!(actor: current_user, action: "nps_comment_author_viewed", subject: @answer)
      @author = @answer.user.display_name.presence || "No display name on file"
    end
  end
end
