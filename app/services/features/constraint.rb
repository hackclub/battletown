module Features
  # A route constraint: the routes inside it exist only while the flag is on, otherwise the request falls through to
  # the same 404 as any unknown path. An unknown flag name raises when the routes are drawn (at boot), and drawing
  # never reads the flag store.
  #
  #   constraints Features::Constraint.new(:team) do
  #     resource :team
  #   end
  class Constraint
    def initialize(name)
      @name = Features.validate!(name)
    end

    def matches?(_request) = Features.enabled?(@name)
  end
end
