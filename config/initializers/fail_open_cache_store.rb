# Wraps a cache store for Rack::Attack so that a broken or missing cache (database down, cache table not
# migrated yet) never turns every request into a 500: any error is swallowed, so a throttle counts as 1
# (under the limit) and the request goes through. Solid Cache only rescues transient connection errors
# itself; a missing table raises ActiveRecord::StatementInvalid, and Rack::Attack 6.8 has no error handler.
#
# Errors are logged by class name only, at most once a minute per process: exception messages can embed
# the SQL and with it throttle keys, which contain client IP addresses.
class FailOpenCacheStore
  LOG_INTERVAL = 60 # seconds
  FALLBACKS = { read: nil, write: false, increment: nil, delete: false, delete_matched: nil }.freeze

  def initialize(store, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @store = store
    @clock = clock
    @last_logged = nil
  end

  FALLBACKS.each do |method_name, fallback|
    define_method(method_name) do |*args, **options|
      @store.public_send(method_name, *args, **options)
    rescue StandardError => error
      log_failure(method_name, error)
      fallback
    end
  end

  private

  def log_failure(method_name, error)
    now = @clock.call
    return if @last_logged && now - @last_logged < LOG_INTERVAL

    @last_logged = now
    Rails.logger.error("Rack::Attack cache store failed (#{method_name}: #{error.class}); throttling is failing open")
  end
end
