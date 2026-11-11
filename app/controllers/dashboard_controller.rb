class DashboardController < ApplicationController
  before_action :require_login, :require_onboarded

  def show
  end
end
