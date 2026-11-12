# For the staff controllers nested under /admin/users/:user_id: finds the person (an unknown id is the plain 404).
module AdminUserScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_user
  end

  private

  def set_user = @user = User.find(params[:user_id])
end
