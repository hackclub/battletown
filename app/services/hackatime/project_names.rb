module Hackatime
  # The names of the Hackatime projects a person has coded on, so the link page can offer them in a list instead of asking
  # them to type a name exactly. It asks Hackatime once (GET /api/v1/authenticated/projects over the last year, or since the project
  # time cutoff when that is later, archived ones included, the same endpoint the hours source reads) and keeps only names the app can link (see HackatimeLink::NAME_FORMAT).
  # Names are the person's own and are never logged or cached.
  #
  #   result = Hackatime::ProjectNames.for(user)
  #   result.ok?    # false: no connection, it needs reconnecting, or Hackatime did not answer: offer a typed field instead
  #   result.names  # sorted, de-duplicated, without any name this person has already linked
  class ProjectNames
    Result = Data.define(:ok, :names) do
      def ok? = ok
    end

    LOOKBACK_DAYS = 365
    MAX_NAMES = 500

    def self.for(user, client_factory: ->(connection) { Client.new(connection) }) = new(user, client_factory).result

    def initialize(user, client_factory)
      @user = user
      @client_factory = client_factory
    end

    def result
      connection = @user.hackatime_connection
      return failed if connection.nil? || connection.needs_reconnect?

      body = @client_factory.call(connection).get_json("/api/v1/authenticated/projects", start_date: window_start.iso8601(3),
                                                       end_date: Time.current.iso8601(3), include_archived: "true")
      Result.new(ok: true, names: usable(Array(body["projects"])))
    rescue Client::Error
      failed
    end

    private

    def failed = Result.new(ok: false, names: [])

    # The last year, but never before the project time cutoff (ships.project_time_from): time before it does not count on a
    # project, so a project coded on only before it is not offered.
    def window_start
      zone = ActiveSupport::TimeZone[@user.time_zone.to_s] || ActiveSupport::TimeZone["UTC"]
      year_ago = zone.now.beginning_of_day - LOOKBACK_DAYS.days
      cutoff = Ships::Config.current.project_time_from
      cutoff ? [ year_ago, zone.local(cutoff.year, cutoff.month, cutoff.day) ].max : year_ago
    end

    def usable(projects)
      linked = HackatimeLink.where(user_id: @user.id).pluck(:hackatime_project).to_set
      names = projects.filter_map { |project| project["name"].to_s.strip if project.is_a?(Hash) }
      names.uniq.select { |name| name.length <= HackatimeLink::NAME_MAX && name.match?(HackatimeLink::NAME_FORMAT) && !linked.include?(name) }
           .sort_by { |name| [ name.downcase, name ] }.first(MAX_NAMES)
    end
  end
end
