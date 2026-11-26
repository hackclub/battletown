require "openssl"

module Bosses
  # Who is fighting the boss on the dashboard stage: the people who coded in a ROLLING last 24 hours (not on the UTC calendar
  # day, which would send every circle away at the same midnight), as one small snapshot the stage draws and the live endpoint
  # (BossFightersController) serves.
  #
  # A FIGHTER is a person whose entries in the hours ledger that were RECORDED (`hour_entries.recorded_at`, when the time arrived)
  # less than 24 hours ago add up to at least `Hours::Config#active_seconds` (15 minutes), counted across all their projects, so
  # one person is one circle. Only entries on COUNTED dates are read (Hours::Totals.counted: the sign-up cutoff), and nobody else
  # is excluded (staff and simulated players count like anyone). Adjustments are entries like any other. An entry also has to be
  # dated on a day that "now" can be on somewhere (the UTC date, a day either way), so time backfilled from an old day when someone
  # links Hackatime does not show up as a day's work.
  #
  # A circle says three things: how much they coded in that time (a SIZE band, 1 to 5, against the daily goal), whether they
  # SHIPPED (a submitted or approved ship in this boss's week, submitted in the last 24 hours: the boss takes its damage, see
  # Bosses::Damage) and so how they hit the boss, their TIER:
  #
  #   :ship   shipped: a heavy hit
  #   :code   coded at least the daily goal (Game::Config goal_seconds, 60 minutes) but did not ship: a light hit
  #   :idle   less than that: warming up
  #
  # Every player has a profile, so every circle shows the player's name (PublicProfile.name_for: the display name they chose, else
  # their Slack name, else a generated handle), links to their profile page by its opaque address and wears their Slack picture when
  # they use it. The key that tells one circle from another is a keyed hash of the person and the boss week, not an id and not the
  # address, so it cannot be turned back into one and changes every boss week. No id, email, real name, Slack id or exact minutes is
  # ever in a circle's text or in the JSON.
  #
  # One query finds the people (with the total and the number of shippers over ALL of them, the circles being the 12 most active:
  # shippers first, then the most coded), and the result is cached for 20 seconds, shared by everybody, per boss and minute.
  module Fighters
    WINDOW = 24.hours
    # The most circles the stage draws, however many people coded.
    LIMIT = 12
    CACHE_FOR = 20.seconds

    # One circle. `minutes` stays on the server (the text says it roughly). `you` is only ever set for the person looking
    # (Circle#for_viewer).
    #
    # `avatar` is the version tag of the player's Slack picture copy (SlackProfiles), only for a player who has one; the
    # circle then shows it (from this app's own /players/:slug/avatar, never Slack) instead of the generated initial.
    Circle = Data.define(:key, :name, :slug, :tone, :size, :tier, :minutes, :you, :avatar) do
      def initialize(avatar: nil, **fields) = super(avatar: avatar, **fields)

      # This app's address of the picture, nil when there is none (the circle keeps the generated avatar).
      def avatar_url = (Rails.application.routes.url_helpers.player_avatar_path(slug, v: avatar) if avatar)

      def initial = name.first.upcase

      # How this circle moves (FighterMotion steps), fixed by its key: the same person keeps the same rhythm, and nobody shares one.
      def motion = FighterMotion.for_key(key)

      # The player's profile page.
      def path = Rails.application.routes.url_helpers.player_path(slug)

      def title = you ? "You (#{name})" : name

      def detail = "coded about #{duration_text} in the last day"

      def status
        case tier
        when :ship then "shipped a project: hit the boss"
        when :code then "hits it with a steady pace"
        else "warming up"
        end
      end

      def hint = (you ? "Click to see your profile" : "Click to see their profile")

      # What a screen reader says for the circle, and what the card shows: the same words.
      def label = "#{title}: #{detail}, #{status}.#{" #{hint}." if hint}"

      def for_viewer(viewer_key) = with(you: key == viewer_key)

      private

      # "about 25 min", "about 2 h", "about 2.5 h": rounded, so it is not an exact record of anyone's day.
      def duration_text
        return "#{[ (minutes / 5.0).round * 5, 5 ].max} min" if minutes < 60

        halves = (minutes / 30.0).round
        "#{halves.even? ? halves / 2 : halves / 2.0} h"
      end
    end

    # `circles` are the (at most) 12 drawn, `total` everybody who coded and `shippers` how many of all of them shipped.
    Snapshot = Data.define(:circles, :total, :shippers)

    # For a page that has no use for the fighters (the signed-out landing page reads only the boss's health).
    NOBODY = Snapshot.new(circles: [].freeze, total: 0, shippers: 0)

    module_function

    # The snapshot for `boss` (nil between bosses: nobody has shipped into a boss, so no circle is a shipper), as of `now`.
    def call(boss, now: Time.current)
      Rails.cache.fetch([ "bosses", "fighters", boss&.id || 0, now.to_i / 60 ], expires_in: CACHE_FOR) { load(boss, now) }
    end

    # The key one person's circle has in this boss's week. Stable inside the week (the page can follow a circle as it changes), a
    # keyed hash of a different value each week (so it is not an id, and not a handle to follow someone from week to week).
    def key_for(user_id, boss)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("bosses/fighters/key"), "#{boss&.id}:#{user_id}").first(12)
    end

    # How big a circle is, 1 to 5, from the seconds coded against the daily goal: under half a goal, under one, under two, under
    # four, more.
    def size_for(seconds, goal: Game::Config.current.goal_seconds)
      return 1 if seconds * 2 < goal
      return 2 if seconds < goal
      return 3 if seconds < goal * 2

      seconds < goal * 4 ? 4 : 5
    end

    def tier_for(seconds, shipped, goal: Game::Config.current.goal_seconds)
      return :ship if shipped

      seconds >= goal ? :code : :idle
    end

    # Drops every cached snapshot (the development event simulator, so a change shows at once instead of in up to 20 seconds).
    def forget = Rails.cache.delete_matched("bosses/fighters/*")

    # Drops the one cached snapshot `call` would read for this boss right now (Bosses::Live, so a pushed update is not up to 20 seconds old).
    # A plain delete, which every cache store supports (delete_matched above does not exist on Solid Cache).
    def forget_for(boss, now: Time.current) = Rails.cache.delete([ "bosses", "fighters", boss&.id || 0, now.to_i / 60 ])

    def load(boss, now)
      since = now - WINDOW
      day = now.utc.to_date
      per_user = Hours::Totals.counted.where(local_date: (day - 1)..(day + 1)).where("hour_entries.recorded_at > ?", since)
                              .joins("LEFT JOIN slack_profiles ON slack_profiles.user_id = users.id")
                              .group("users.id").having("SUM(hour_entries.seconds) >= ?", Hours::Config.current.active_seconds)
                              .select("users.id AS user_id, users.profile_name, users.public_slug, " \
                                      "MAX(CASE WHEN slack_profiles.use_name THEN slack_profiles.display_name END) AS slack_name, " \
                                      "MAX(CASE WHEN slack_profiles.use_picture THEN LEFT(slack_profiles.picture_sha256, 10) END) AS avatar_v, " \
                                      "SUM(hour_entries.seconds) AS seconds, #{shipped_sql(boss, since)} AS shipped")
      rows = HourEntry.from(per_user, :fighters)
                      .select("fighters.*, COUNT(*) OVER () AS total, COUNT(*) FILTER (WHERE fighters.shipped) OVER () AS shippers")
                      .order("fighters.shipped DESC, fighters.seconds DESC, fighters.user_id").limit(LIMIT).to_a
      Snapshot.new(circles: rows.map { |row| circle(row, boss) }, total: rows.first&.[]("total").to_i, shippers: rows.first&.[]("shippers").to_i)
    end

    # Whether the person has a ship in the boss's week that was submitted in the window (the ships that hit it).
    def shipped_sql(boss, since)
      return "FALSE" unless boss

      "EXISTS (#{Damage.ships_in(boss).where('ships.submitted_at > ?', since).where('ships.user_id = users.id').select(1).to_sql})"
    end

    def circle(row, boss)
      seconds = row["seconds"].to_i
      slug = row["public_slug"]
      Circle.new(key: key_for(row["user_id"], boss), slug: slug, tone: Profiles::Presenter.tone_for(slug), avatar: row["avatar_v"].presence,
                 name: PublicProfile.name_for(profile_name: row["profile_name"], slack_name: row["slack_name"], slug: slug),
                 size: size_for(seconds), tier: tier_for(seconds, row["shipped"]), minutes: seconds / 60, you: false)
    end
    private_class_method :load, :shipped_sql, :circle
  end
end
