module Features
  # Lets only a signed-in admin through to the Flipper UI; everyone else (signed out or not an admin) falls through to
  # the 404 an unknown path gets. Reads the session the way ApplicationController does and re-checks admin? from the
  # database user on every request.
  class AdminConstraint
    def matches?(request)
      user_id = request.session[:user_id]
      user_id.present? && User.find_by(id: user_id)&.admin? == true
    end
  end
end
