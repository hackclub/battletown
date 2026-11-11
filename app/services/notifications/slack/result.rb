module Notifications
  module Slack
    # `ok` - delivered. `retryable` - worth trying again later. `error_code` - a short snake_case code, never the
    # token, recipient or message text. `retry_after` - seconds the server asked us to wait (rate limits).
    # `systemic` - the failure is about our credentials or setup, not this recipient, so the whole run should stop.
    Result = Struct.new(:ok, :retryable, :error_code, :retry_after, :systemic, keyword_init: true) do
      def self.success = new(ok: true, retryable: false)

      def self.failure(error_code, retryable:, retry_after: nil, systemic: false)
        new(ok: false, retryable: retryable, error_code: error_code, retry_after: retry_after, systemic: systemic)
      end

      def ok? = ok == true
    end
  end
end
