module Admin
  class DashboardController < BaseController
    def show
      @stats = AdminStats.call
    end
  end
end
