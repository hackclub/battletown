module Admin
  class DashboardController < BaseController
    def show
      @stats = AdminStats.call
      @pending_ships = Ship.waiting.count
    end
  end
end
