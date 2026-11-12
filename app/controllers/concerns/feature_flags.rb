# `feature?(:team)` in controllers and views, and `require_feature!(:team)` for a controller whose pages exist only
# while a flag is on. Included in ApplicationController. See app/services/features.rb.
module FeatureFlags
  extend ActiveSupport::Concern

  included do
    helper_method :feature?
  end

  private

  def feature?(name, actor = nil) = Features.enabled?(name, actor)

  # While the flag is off the response is exactly the 404 an unknown path gets (same as a non-admin on /admin).
  #   before_action { require_feature!(:team) }
  def require_feature!(name, actor = nil)
    raise ActionController::RoutingError, "Not Found" unless feature?(name, actor)
  end
end
