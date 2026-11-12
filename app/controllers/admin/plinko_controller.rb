module Admin
  # Plinko aggregates: drops and players per day and week. Read-only, no names, nicknames or ids, and no actions
  # (there is deliberately nothing to reset or award). Behind the `plinko` flag as well as the admin check.
  class PlinkoController < BaseController
    before_action { require_feature!(:plinko) }

    def show
      @stats = Plinko::AdminStats.call
    end
  end
end
