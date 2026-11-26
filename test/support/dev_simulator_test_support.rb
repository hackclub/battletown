# Shared setup for the event simulator tests: a boss for this week, and the database counted as local whatever the
# machine's own settings say (CI may reach Postgres by a host name).
module DevSimulatorTestSupport
  include BossesHelper

  def local_database!
    @original_host = DevSimulator.method(:effective_host)
    @original_hostaddr = DevSimulator.method(:effective_hostaddr)
    @original_service = DevSimulator.method(:effective_service)
    DevSimulator.define_singleton_method(:effective_host) { nil }
    DevSimulator.define_singleton_method(:effective_hostaddr) { nil }
    DevSimulator.define_singleton_method(:effective_service) { nil }
  end

  def restore_database_host!
    DevSimulator.define_singleton_method(:effective_host, @original_host) if @original_host
    DevSimulator.define_singleton_method(:effective_hostaddr, @original_hostaddr) if @original_hostaddr
    DevSimulator.define_singleton_method(:effective_service, @original_service) if @original_service
  end

  # The date a ship made now lands on (boss weeks are UTC dates).
  def utc_today = Time.current.utc.to_date

  # A boss whose week covers today (and the week before it, so a user whose own day is a day away still has one).
  def make_current_boss(hp_seconds: 500 * HOUR)
    friday = friday_on_or_before(utc_today)
    make_boss(starts_on: friday - 7, hp_seconds: hp_seconds)
    make_boss(starts_on: friday, hp_seconds: hp_seconds)
  end
end
