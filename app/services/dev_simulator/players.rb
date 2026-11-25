module DevSimulator
  # Makes sure simulated players 1..`count` exist and have coded a little today. Run it again and nothing doubles: a player is
  # found by its counter ("sim!7"), and the coded time is credited under a key for the day, so a second call only fills in
  # what is missing (a new day gets fresh minutes). `count` is the number of players you want, not the number to add.
  #
  # A player is onboarded, signed up about a month ago, has a prize, an active project with a linked Hackatime name, and
  # 15 to 90 minutes in the ledger for `today` (written through Hours::Credit, source "manual"), so the boss's "N people coded
  # today" and the fighter circles count them. Their ships come from DevSimulator::Ship.
  class Players
    Result = Data.define(:created, :existing, :credited, :total)

    ANIMALS = %w[Otter Fox Heron Lynx Panda Gecko Newt Moth Wren Hare].freeze
    TIME_ZONES = [ "UTC", "Eastern Time (US & Canada)", "Pacific Time (US & Canada)", "London", "Berlin", "Tokyo", "Sydney" ].freeze
    SIGNED_UP_DAYS_AGO = 30
    CODED_MINUTES = (15..90)

    def self.call(**args) = new(**args).call

    def initialize(count:, today:, random: Random.new, now: Time.current)
      @count = count
      @today = today
      @random = random
      @now = now
    end

    def call
      DevSimulator.check_local_database!
      count = DevSimulator.whole_number(@count, 1..MAX_CREATE, "players")
      known = DevSimulator.players.where(hca_uid: uids(count)).index_by(&:hca_uid)
      missing = count - known.size
      raise Refused, "At most #{MAX_PLAYERS} simulated players can exist at once." if DevSimulator.players.count + missing > MAX_PLAYERS

      credited = 0
      (1..count).each do |counter|
        player = known[uid(counter)] || create_player(counter)
        credited += 1 if credit_today(player)
      end
      Result.new(created: missing, existing: known.size, credited: credited, total: DevSimulator.players.count)
    end

    private

    def uid(counter) = "#{UID_PREFIX}#{counter}"

    def uids(count) = (1..count).map { |counter| uid(counter) }

    def create_player(counter)
      User.transaction do
        user = User.create!(hca_uid: uid(counter), display_name: "Sim #{ANIMALS[counter % ANIMALS.size]} #{counter}",
                            verification_status: "verified", ysws_eligible: true, prize_key: Prize.paid.map(&:key).sample(random: @random),
                            project_kind: "game", time_zone: TIME_ZONES.sample(random: @random), coding_days: 31, coding_time: "18:00",
                            onboarding_step: User::ONBOARDING_STEPS, onboarded_at: @now, created_at: @now - SIGNED_UP_DAYS_AGO.days)
        project = Project.create!(user: user, name: "Sim project 1", kind: "game")
        project.hackatime_links.create!(user: user, hackatime_project: "sim-#{counter}-#{project.id}", link_method: "manual")
        user
      end
    end

    # True when this call wrote the day's minutes (a duplicate or a full day writes nothing).
    def credit_today(player)
      minutes = @random.rand(CODED_MINUTES)
      Hours::Credit.call(user: player, seconds: minutes * 60, source: "manual", local_date: @today, note: "Simulated player",
                         created_by: CREATED_BY, idempotency_key: "sim:today:#{@today.iso8601}").created?
    rescue Hours::Credit::Rejected
      false
    end
  end
end
