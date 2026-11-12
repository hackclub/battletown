module Plinko
  # Makes the nickname a player shows on the leaderboard: "<adjective> <animal> <10..99>" from the fixed word lists in
  # config/game.yml. It takes no name or other input about the player, so it can never be derived from one.
  module Nicknames
    ATTEMPTS = 25

    module_function

    def random(config: Config.current, rng: SecureRandom)
      "#{config.nickname_adjectives.sample(random: rng)} #{config.nickname_animals.sample(random: rng)} #{rng.random_number(10..99)}"
    end

    # A nickname nobody else has (case-insensitive) and that is not `except`. The unique index has the last word: a
    # caller that loses a race gets RecordNotUnique and asks again.
    def generate(except: nil, config: Config.current, rng: SecureRandom)
      ATTEMPTS.times do
        name = random(config: config, rng: rng)
        next if name.casecmp?(except.to_s)
        return name unless PlinkoPlayer.where("lower(nickname) = ?", name.downcase).exists?
      end
      raise "Plinko: no free nickname after #{ATTEMPTS} tries (add words to config/game.yml)"
    end
  end
end
