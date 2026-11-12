module Hca
  # Revokes the one-time tokens of an address lookup at Hack Club Auth (POST /oauth/revoke), best effort and time-boxed: it
  # never raises, never retries, and gives up on whatever is left once BUDGET seconds have gone. The tokens are only ever held
  # in memory by the caller; this is the last place they are used. Nothing is logged but a count.
  module TokenRevoker
    BUDGET = 4.0
    CALL_TIMEOUT = 2.0

    module_function

    # Returns how many revoke calls Hack Club Auth acknowledged (200).
    def call(*tokens, http: nil)
      return 0 if Hca.client_id.blank?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BUDGET
      acknowledged = 0
      tokens.flatten.compact_blank.uniq.each do |token|
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if left < 0.1

        timeout = [ CALL_TIMEOUT, left ].min
        client = http || Http.new(open_timeout: timeout, read_timeout: timeout)
        acknowledged += 1 if client.post_form("/oauth/revoke", token: token, client_id: Hca.client_id, client_secret: Hca.client_secret.to_s).status == 200
      rescue StandardError
        next
      end
      acknowledged
    rescue StandardError
      0
    end
  end
end
