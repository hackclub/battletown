# The development-only event simulator behind the panel on the dashboard (app/views/dashboard/_simulator.html.erb,
# Dev::SimulatorController). The weekly boss is only hurt by SHIPPED hours, so to watch it take damage in a local
# database you need other people shipping: this makes them.
#
# A simulated player is a real users row whose hca_uid starts with "sim!" (real ids look like "ident!..."). That prefix is
# the only thing that marks them, and every service here only ever reads or deletes users that carry it. Nothing here
# holds personal data: no email, no Slack id, names like "Sim Otter 12".
#
#   DevSimulator::Players.call(count: 20, today: date)      # make sure players 1..20 exist and have coded today
#   DevSimulator::Ship.call(mode: "percent", percent: 30, today: date)
#   DevSimulator::Status.call(user: current_user)           # aggregates for the panel
#   DevSimulator::Reset.call                                # delete the simulated players and everything about them
#
# Every service refuses unless the database looks like it is on this machine (see `local_database?`), so a stray DATABASE_URL
# pointing at a shared or production database is not filled with made-up players. It reads the connection settings, so an SSH
# tunnel or port-forward to a remote database on localhost is not detected.
module DevSimulator
  # Something the caller asked for that cannot be done; the message is plain language for the panel.
  class Refused < StandardError; end

  UID_PREFIX = "sim!".freeze
  MAX_PLAYERS = 500 # simulated players that may exist at once
  MAX_CREATE = 200 # the most one "create players" call asks for
  MAX_HOURS = 100 # the most hours one simulated ship may hold (Ship writes what the daily cap cannot hold as adjustments)
  DEFAULT_HOURS_MIN = 1 # the hours range a ship is drawn from when the panel sends none (and what its inputs start at)
  DEFAULT_HOURS_MAX = 8
  CREATED_BY = "dev:sim".freeze # the operator tag on every ledger row written here (HourEntry::CREATED_BY_FORMAT)
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  LOOPBACK_ADDRESSES = %w[127.0.0.1 ::1].freeze

  module_function

  # Only the simulated players, never anyone else.
  def players = User.where("users.hca_uid LIKE ?", "#{User.sanitize_sql_like(UID_PREFIX)}%")

  # Where the database lives: the configured host, else the PGHOST the Postgres client would fall back to. nil is a unix socket.
  def effective_host
    ActiveRecord::Base.connection_db_config.configuration_hash[:host].presence || ENV["PGHOST"].presence
  end

  # A numeric address that makes libpq connect there whatever the host says, from the config or PGHOSTADDR.
  def effective_hostaddr
    ActiveRecord::Base.connection_db_config.configuration_hash[:hostaddr].presence || ENV["PGHOSTADDR"].presence
  end

  # A connection service (config or PGSERVICE) that may supply the host from a pg_service.conf we do not read.
  def effective_service
    ActiveRecord::Base.connection_db_config.configuration_hash[:service].presence || ENV["PGSERVICE"].presence
  end

  # Local means this machine: no host (unix socket), localhost or a loopback address, or a socket directory, with no other
  # address or service setting pointing somewhere else. A service is refused when the host is blank, because the host then
  # comes from a file we cannot see.
  def local_database?(host = effective_host, hostaddr: effective_hostaddr, service: effective_service)
    host = host.to_s.strip.downcase
    return false unless hostaddr.to_s.strip.empty? || LOOPBACK_ADDRESSES.include?(hostaddr.to_s.strip.downcase)
    return false if host.empty? && service.present?

    host.empty? || LOCAL_HOSTS.include?(host) || host.start_with?("/")
  end

  def check_local_database!
    return if local_database?

    raise Refused, "The event simulator only writes to a database on this machine, and this one is not (host #{effective_host.to_s.first(60)})."
  end

  # `value` as a whole number inside `range`, else a Refused that says what was expected. Strings from a form are fine.
  def whole_number(value, range, name)
    number = value.is_a?(Integer) ? value : Integer(value.to_s.strip, 10, exception: false)
    raise Refused, "#{name} must be a whole number from #{range.min} to #{range.max}" unless number && range.cover?(number)

    number
  end
end
