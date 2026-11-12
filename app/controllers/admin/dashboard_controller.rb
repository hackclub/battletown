module Admin
  class DashboardController < BaseController
    def show
      @stats = AdminStats.call
      @pending_ships = Ship.waiting.count
      @project_reviews = Project.group(:review_status).count
    end
  end
end
