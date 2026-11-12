module Teams
  # What the dashboard card and the crew page show about the person's own crew: the size and the coins THEY earned from it.
  # Never anything about another member (no names here, no hours, no coins).
  module Summary
    Snapshot = ::Data.define(:team, :member_count, :max_size, :bonus_coins, :bonus_ships) do
      def in_crew? = !team.nil?
    end

    module_function

    def for(user, config: Config.current)
      membership = TeamMembership.includes(:team).find_by(user_id: user.id)
      earned = TeamPayout.where(user_id: user.id)
      coins = earned.sum(:coins)
      ships = earned.where("coins > 0").count
      return Snapshot.new(team: nil, member_count: 0, max_size: config.max_size, bonus_coins: coins, bonus_ships: ships) unless membership

      Snapshot.new(team: membership.team, member_count: TeamMembership.where(team_id: membership.team_id).count, max_size: config.max_size,
               bonus_coins: coins, bonus_ships: ships)
    end
  end
end
