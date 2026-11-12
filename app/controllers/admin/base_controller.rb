# Staff-only area. Signed-out visitors and non-admins get exactly the response a missing route gets (404), so
# nothing hints that /admin exists. Admin status is re-checked from the database user on every request.
module Admin
  class BaseController < ApplicationController
    # Prepended so they run before the CSRF check: otherwise a write without a token answers 422 and reveals the
    # route to someone who is not an admin. Admins still get the CSRF check right after.
    prepend_before_action :require_admin!
    prepend_before_action :require_login
    prepend_before_action :set_no_store

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
