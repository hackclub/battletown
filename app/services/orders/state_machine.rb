module Orders
  # The whole order lifecycle in one table, and nothing else: pure functions, no database, no clock. Every service asks
  # this before it changes anything, and the docs and tests read the same table.
  #
  #   requested -> on_hold | shipped | fulfilled | cancelled
  #   on_hold   -> requested (release) | cancelled
  #   shipped   -> fulfilled | refunded
  #   fulfilled -> refunded
  #   cancelled, refunded: final
  #
  # Actors: the buyer (only cancels, only while `requested`) and staff (everything else; re-checked as an admin by the
  # service). A staff cancel or refund must give a reason code. Cancel and refund are the two moves that give coins back.
  module StateMachine
    Rule = Data.define(:action, :from, :to, :actor)

    ACTIONS = %w[hold release ship fulfil cancel refund].freeze
    ACTORS = %w[buyer staff].freeze
    # The move an action makes, and the history entry it writes.
    TARGETS = { "hold" => "on_hold", "release" => "requested", "ship" => "shipped", "fulfil" => "fulfilled", "cancel" => "cancelled",
                "refund" => "refunded" }.freeze
    EVENT_ACTIONS = { "hold" => "held", "release" => "released", "ship" => "shipped", "fulfil" => "fulfilled", "cancel" => "cancelled",
                      "refund" => "refunded" }.freeze

    RULES = [
      Rule.new("hold", "requested", "on_hold", "staff"),
      Rule.new("release", "on_hold", "requested", "staff"),
      Rule.new("ship", "requested", "shipped", "staff"),
      Rule.new("fulfil", "requested", "fulfilled", "staff"),
      Rule.new("fulfil", "shipped", "fulfilled", "staff"),
      Rule.new("cancel", "requested", "cancelled", "buyer"),
      Rule.new("cancel", "requested", "cancelled", "staff"),
      Rule.new("cancel", "on_hold", "cancelled", "staff"),
      Rule.new("refund", "shipped", "refunded", "staff"),
      Rule.new("refund", "fulfilled", "refunded", "staff")
    ].freeze

    # Moves that give the coins back with one `refund` ledger entry.
    REFUNDING = %w[cancel refund].freeze
    # Staff must pick a reason code for these (the buyer's own cancel needs none).
    REASON_REQUIRED = %w[cancel refund].freeze

    module_function

    def allowed?(action, from, actor) = RULES.any? { |rule| rule.action == action.to_s && rule.from == from.to_s && rule.actor == actor.to_s }

    def target(action) = TARGETS[action.to_s]

    def event_action(action) = EVENT_ACTIONS[action.to_s]

    # Is this actor ever allowed to do this action (from any status)? Decides "not yours to do" before "not now".
    def actor_may?(action, actor) = RULES.any? { |rule| rule.action == action.to_s && rule.actor == actor.to_s }

    # Already there: asking again for the move that lands on the status the order is in is a harmless repeat.
    def already?(action, status) = target(action) == status.to_s

    def actions_for(status, actor) = ACTIONS.select { |action| allowed?(action, status, actor) }

    def final?(status) = RULES.none? { |rule| rule.from == status.to_s }

    def refunds?(action) = REFUNDING.include?(action.to_s)

    def reason_required?(action, actor) = actor.to_s == "staff" && REASON_REQUIRED.include?(action.to_s)
  end
end
