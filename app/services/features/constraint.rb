module Features
  # A route constraint: the routes inside it exist only while the flag is on, otherwise the request falls through to
  # the same 404 as any unknown path. An unknown flag name raises when the routes are drawn (at boot), and drawing
  # never reads the flag store.
  #
  #   constraints Features::Constraint.new(:team) do
  #     resource :team
  #   end
  class Constraint
    # The flag this constraint guards (the router tests read it to prove every flagged route sits inside its own flag).
    attr_reader :name

    def initialize(name)
      @name = Features.validate!(name)
    end

    def matches?(_request) = Features.enabled?(@name)
  end
end
