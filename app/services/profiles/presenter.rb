require "zlib"

module Profiles
  # Everything a player's profile page shows, as plain values (no ActiveRecord objects leak into the view). Build one per request:
  #
  #   profile = Profiles::Presenter.new(user: owner, viewer: current_user)
  #
  # `user` is whose profile it is and `viewer` is who is looking. The caller (ProfilesController) has already checked the viewer is
  # signed in and onboarded (every such player may open any profile); this class decides WHAT is shown, and it is deliberately short:
  #
  #   always       the name (PublicProfile.name_for: the display name they chose, else their Slack name, else a generated handle), an
  #                avatar (their Slack picture from this app's own copy when they use it, else their initial on a colour taken from
  #                the opaque address), "fighting since <month year>", damage to the boss this boss week and all-time, bosses
  #                slain, the 15-minute streak, and up to 20 live projects (name, kind, how many ships, latest ship status, repo
  #                and demo links when they are https).
  #   own page     also the ships (with status and a link) and the settings link.
  #
  # Never read here, so never shown: email, Slack id, the real name Hack Club Auth gives (users.display_name), address, coding schedule, per-day hours, coins, prize,
  # project ideas and to-dos, drafts and rejected ships (a rejection is between the person and the reviewer).
  #
  # Queries are bounded, however many projects or ships someone has: a handful for the numbers, one each for projects and the
  # newest ship per project, and one for the owner's own ships.
  class Presenter
    PROJECT_LIMIT = 20
    SHIP_LIMIT = 20
    # The avatar colours (css `avatar--tone-N`); a person's tone is fixed by their address, so it never changes under them.
    TONES = 12

    ProjectCard = Data.define(:name, :kind, :ships_count, :latest_status, :repo_url, :demo_url)
    ShipRow = Data.define(:id, :project_name, :status, :seconds, :on)

    attr_reader :user, :viewer, :now

    def initialize(user:, viewer:, now: Time.current)
      @user = user
      @viewer = viewer
      @now = now
    end

    def own? = viewer.present? && viewer.id == user.id

    # The name everybody sees (a Slack name only when they use it and have no display name of their own).
    def name = @name ||= user.public_name

    def initial = name.first.to_s.upcase

    # The opaque address segment. The page's own link is player_path(slug).
    def slug = user.public_slug

    def tone = self.class.tone_for(slug)

    # The colour of a player's avatar, fixed by their address (the boss stage draws the same avatar, Bosses::Fighters).
    def self.tone_for(slug) = Zlib.crc32(slug) % TONES

    # This app's address of their Slack picture (SlackProfiles), nil without one: the page then keeps the generated avatar. The
    # version tag makes a changed picture a new address.
    def avatar_url
      version = SlackProfile.picture_version(user.id)
      Rails.application.routes.url_helpers.player_avatar_path(slug, v: version) if version
    end

    def since_text = "Fighting since #{user.signed_up_on.strftime('%B %Y')}"

    # --- damage (seconds; the view words them) ---

    # The boss that is live today (UTC date, as Bosses::Damage puts ships in weeks) or nil between bosses.
    def boss
      return @boss if defined?(@boss)

      current = Bosses::Current.at(now)
      @boss = current == :none ? nil : current
    end

    def boss_name = boss&.name

    # The coded hours on their submitted and approved ships in this boss week (Bosses::Damage.for_user), 0 when no boss is on.
    def week_damage_seconds = @week_damage_seconds ||= boss ? Bosses::Damage.for_user(boss, user) : 0

    def all_time_damage_seconds = @all_time_damage_seconds ||= Bosses::Damage.all_time_for_user(user)

    # The number of fallen bosses they earned the Boss slayer badge on.
    def bosses_slain = @bosses_slain ||= Bosses::Damage.slain_count(user)

    # Days in a row of 15 minutes of coding, as it stands now (today counts once it has reached 15 minutes).
    def streak_days = @streak_days ||= Dashboard::Streaks.call(user: user, today: Hours::Days.today(user, now: now)).quick_days

    # --- projects ---

    # Their live (not archived) projects, newest first, at most PROJECT_LIMIT. A project's ship count and latest status only
    # count ships that were handed in (submitted or approved): drafts are private, and a "needs changes" is not for others.
    def projects
      @projects ||= begin
        rows = Project.live.where(user_id: user.id).newest_first.limit(PROJECT_LIMIT).pluck(:id, :name, :kind, :repo_url, :demo_url)
        ids = rows.map(&:first)
        counts = Ship.where(project_id: ids, status: Ship::WINDOW_STATUSES).group(:project_id).count
        latest = latest_status_by_project(ids)
        rows.map do |id, name, kind, repo, demo|
          ProjectCard.new(name: name, kind: kind, ships_count: counts.fetch(id, 0), latest_status: latest[id],
                          repo_url: https(repo), demo_url: https(demo))
        end
      end
    end

    # --- the owner's own page only ---

    # Their ships, newest first, every status (it is their own page). Empty for anyone else.
    def ships
      return [] unless own?

      @ships ||= Ship.where(user_id: user.id).newest_first.limit(SHIP_LIMIT).joins(:project)
                     .pluck(Arel.sql("ships.id"), Arel.sql("projects.name"), Arel.sql("ships.status"), Arel.sql(Bosses::Damage::SECONDS),
                            Arel.sql("COALESCE(ships.submitted_at, ships.created_at)"))
                     .map { |id, project, status, seconds, at| ShipRow.new(id: id, project_name: project, status: status, seconds: seconds, on: Hours::Days.local_date(at, user)) }
    end

    private

    # { project_id => status of its newest handed-in ship }, one query.
    def latest_status_by_project(ids)
      return {} if ids.empty?

      Ship.where(project_id: ids, status: Ship::WINDOW_STATUSES).order(Arel.sql("ships.project_id, ships.submitted_at DESC, ships.id DESC"))
          .select(Arel.sql("DISTINCT ON (ships.project_id) ships.project_id, ships.status")).to_h { |ship| [ ship.project_id, ship.status ] }
    end

    # Only an https address can become a link; the values were validated when saved, this is the second check.
    def https(url) = (url.to_s if url.to_s.start_with?("https://"))
  end
end
