# Development-only: Basecoat (shadcn's components as plain HTML classes) in the Battletown theme, on its own page and its
# own layout (layouts/basecoat), so the site's component classes (.btn, .card, .input ...) do not mix with Basecoat's.
# No login needed. Outside development every request is a 404 (same as an unknown path); never reachable in test or
# production. See app/assets/tailwind/battletown_theme.css.
module Dev
  class BasecoatController < ApplicationController
    layout "basecoat"
    before_action :require_development!

    def show; end

    private

    def require_development!
      raise ActionController::RoutingError, "Not Found" unless Rails.env.development?
    end
  end
end
