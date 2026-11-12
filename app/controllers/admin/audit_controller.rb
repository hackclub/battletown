module Admin
  # /admin/audit: the staff audit trail (AdminAudit), read-only. Filter by action, staff member and UTC date; 50 a page,
  # newest first. Rows hold ids, amounts and short staff reasons only, so there is nothing personal to show.
  class AuditController < BaseController
    def index
      @action = AdminAudit::ACTIONS.include?(params[:event]) ? params[:event] : nil
      @actor_id = (params[:actor_id].to_s if params[:actor_id].to_s.match?(/\A\d{1,12}\z/))
      @from = parse_date(params[:from])
      @to = parse_date(params[:to])

      scope = AdminAuditEvent.newest_first
      scope = scope.where(action: @action) if @action
      scope = scope.where(actor_id: @actor_id.to_i) if @actor_id
      scope = scope.where(created_at: @from.beginning_of_day..) if @from
      scope = scope.where(created_at: ..@to.end_of_day) if @to

      @pager = AdminPager.new(total: scope.count, page: params[:page])
      @events = @pager.apply(scope).includes(:actor).to_a
      @linkable_users = User.where(id: @events.select { |event| event.subject_type == "User" }.map(&:subject_id)).pluck(:id).to_set
      @staff = User.where(id: AdminAuditEvent.select(:actor_id).distinct).order(:display_name, :id).select(:id, :display_name)
    end

    private

    # A UTC calendar day from YYYY-MM-DD, or nil for anything else (a bad date means "no limit", not an error page).
    def parse_date(raw)
      return nil unless raw.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      date = Date.iso8601(raw.to_s)
      date.year.between?(2000, 2100) ? date.in_time_zone("UTC") : nil
    rescue ArgumentError
      nil
    end
  end
end
