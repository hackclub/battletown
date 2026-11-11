# Staff-only area. Signed-out visitors and non-admins get exactly the response a missing route gets (404), so
# nothing hints that /admin exists. Admin status is re-checked from the database user on every request.
module Admin
  class BaseController < ApplicationController
    before_action :set_no_store
    before_action :require_login
    before_action :require_admin!

    private

    # Same 404 as an unknown path (never the sign-up redirect, which would reveal the area).
    def not_found = raise(ActionController::RoutingError, "Not Found")

    def require_login = (not_found unless signed_in?)

    def require_admin! = (not_found unless current_user.admin?)

    def set_no_store
      response.headers["Cache-Control"] = "no-store"
    end
  end
end
