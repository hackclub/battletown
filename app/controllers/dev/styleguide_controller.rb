# Development-only: the style guide. Every colour token, the type scale and every shared component (docs/CONTRACT.md,
# "Design system") on one page, read from the real stylesheets, so a page can be built and checked against it.
# No login needed. Outside development every request is a 404 (same as an unknown path); never reachable in test or
# production.
module Dev
  class StyleguideController < ApplicationController
    before_action :require_development!

    def show
      @colors = DesignSystem::Tokens.colors
      @contrast = DesignSystem::Contrast.results
      @type_tokens = DesignSystem::Tokens.all.select { |token| token.name.start_with?("--text-") }
      @space_tokens = DesignSystem::Tokens.all.select { |token| token.name.start_with?("--space-") }
      @radius_tokens = DesignSystem::Tokens.all.select { |token| token.name.start_with?("--radius-") }
    end

    private

    def require_development!
      raise ActionController::RoutingError, "Not Found" unless Rails.env.development?
    end
  end
end
