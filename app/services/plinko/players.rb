module Plinko
  # The leaderboard side of a player: a generated nickname and the opt-in switch (default off). Rows are made only
  # here, only while the `plinko` flag is on (the callers are flag-gated), and only for the signed-in player themself.
  module Players
    module_function

    # The player's row, made with a fresh nickname (and the leaderboard off) the first time.
    def for(user)
      PlinkoPlayer.find_by(user_id: user.id) || create(user)
    end

    def opt_in!(user, value)
      player = self.for(user)
      player.update!(leaderboard_opt_in: value)
      player
    end

    # A different nickname, never one that is taken.
    def regenerate!(user)
      player = self.for(user)
      retrying { player.update!(nickname: Nicknames.generate(except: player.nickname)) }
      player
    end

    def create(user)
      retrying { PlinkoPlayer.create!(user: user, nickname: Nicknames.generate, leaderboard_opt_in: false) }
    rescue ActiveRecord::RecordNotUnique
      PlinkoPlayer.find_by!(user_id: user.id) # a second request of the same player won the race
    end

    # Two players can draw the same free nickname at the same moment; the unique index rejects the second, which draws again.
    def retrying
      attempts = 0
      begin
        yield
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
        raise if error.is_a?(ActiveRecord::RecordNotUnique) && error.message.include?("user_id")
        retry if (attempts += 1) < 5
        raise
      end
    end
  end
end
