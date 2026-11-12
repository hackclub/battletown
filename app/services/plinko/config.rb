module Plinko
  # Tunables from config/game.yml under `plinko:`, checked once. Read through `Plinko::Config.current`; tests build a
  # variant with `Plinko::Config.current.with(...)`.
  Config = Data.define(:seconds_per_ball, :max_balls_banked, :ball_expiry_days, :earning_starts_on, :rows, :slot_points,
                       :leaderboard_size, :nickname_adjectives, :nickname_animals) do
    def self.current
      @current ||= from_hash(Rails.application.config_for(:game).fetch(:plinko))
    end

    def self.reset! = @current = nil

    def self.from_hash(hash)
      rows = integer(hash.fetch(:rows), "rows", 1..20)
      slot_points = Array(hash.fetch(:slot_points)).map { |points| integer(points, "slot_points", 0..1_000_000) }.freeze
      raise ArgumentError, "game.yml: plinko.slot_points needs rows + 1 = #{rows + 1} values" unless slot_points.size == rows + 1

      new(
        seconds_per_ball: integer(hash.fetch(:minutes_per_ball), "minutes_per_ball", 1..1440) * 60,
        max_balls_banked: integer(hash.fetch(:max_balls_banked), "max_balls_banked", 1..1000),
        ball_expiry_days: integer(hash.fetch(:ball_expiry_days), "ball_expiry_days", 1..365),
        earning_starts_on: date(hash[:earning_starts_on]),
        rows: rows,
        slot_points: slot_points,
        leaderboard_size: integer(hash.fetch(:leaderboard_size), "leaderboard_size", 1..100),
        nickname_adjectives: words(hash.fetch(:nickname_adjectives), "nickname_adjectives"),
        nickname_animals: words(hash.fetch(:nickname_animals), "nickname_animals")
      )
    end

    def self.integer(value, name, allowed)
      number = Integer(value, exception: false)
      raise ArgumentError, "game.yml: plinko.#{name} #{value.inspect} must be a whole number in #{allowed}" unless number && allowed.cover?(number)

      number
    end

    def self.date(value)
      return nil if value.blank?

      value.is_a?(Date) ? value : Date.iso8601(value.to_s)
    end

    def self.words(list, name)
      list = Array(list).map(&:to_s)
      raise ArgumentError, "game.yml: plinko.#{name} must be unique plain words (letters only)" unless list.size >= 2 && list.uniq.size == list.size && list.all? { |word| word.match?(/\A[A-Za-z]{2,12}\z/) }

      list.freeze
    end
  end
end
