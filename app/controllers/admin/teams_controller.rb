module Admin
  # Staff view of the crews (flag `team`): size and the bonus coins paid, as aggregates. No member names, hours or ids are
  # shown (a crew's name is teen-written free text, shown only here and to the crew). Staff can dissolve a crew: its
  # memberships go with it, the coins already paid stay in the ledger.
  class TeamsController < BaseController
    LIMIT = 200

    before_action { require_feature!(:team) }

    def index
      @teams = Team.order(created_at: :desc).limit(LIMIT).to_a
      @sizes = TeamMembership.where(team_id: @teams.map(&:id)).group(:team_id).count
      @paid = TeamPayout.where(team_id: @teams.map(&:id)).group(:team_id).sum(:coins)
      @crew_count = Team.count
      @people_in_crews = TeamMembership.count
      @total_paid = TeamPayout.sum(:coins)
      @max_size = Teams::Config.current.max_size
    end

    def destroy
      team = Team.find(params[:id])
      ActiveRecord::Base.transaction do
        team.destroy!
        AdminAudit.record!(actor: current_user, action: "crew_dissolved", subject: team)
      end
      redirect_to admin_teams_path, notice: "Dissolved the crew#{" \"#{team.name}\"" if team.name}."
    end
  end
end
