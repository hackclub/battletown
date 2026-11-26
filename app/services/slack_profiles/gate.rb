module SlackProfiles
  # Keeps the profile fetches under Slack's users.info limit (Tier 4, about 100 a minute) and quiet while Slack says to wait. Shared by
  # every process through Rails.cache (Solid Cache in production). Two things:
  #
  #  - `block!(seconds)`: Slack answered 429 with a Retry-After (or the token is wrong or lacks a scope), so nobody calls it for that long;
  #  - `take`: at most PER_MINUTE calls in any clock minute (well under Slack's 100, which leaves room for bursts and other callers).
  #
  # `wait` answers "how many seconds until I may call" (0 means now, and a call is counted). Without a cache that remembers (the test
  # and null stores) nothing is ever held back, which only matters where it is not wanted: a test that needs the limit swaps in a memory store.
  module Gate
    PER_MINUTE = 60
    BLOCK_KEY = "slack_profiles/blocked_until".freeze
    MAX_BLOCK = 3600

    module_function

    def wait(now: Time.current)
      blocked = blocked_for(now)
      return blocked if blocked.positive?

      minute = now.to_i / 60
      key = "slack_profiles/calls/#{minute}"
      Rails.cache.write(key, 0, unless_exist: true, expires_in: 90.seconds)
      count = Rails.cache.increment(key, 1, expires_in: 90.seconds)
      return 0 if count.nil? || count <= PER_MINUTE

      60 - (now.to_i % 60) + 1
    end

    def block!(seconds, now: Time.current)
      seconds = seconds.to_i.clamp(1, MAX_BLOCK)
      Rails.cache.write(BLOCK_KEY, (now + seconds).to_f, expires_in: seconds.seconds)
    end

    def blocked_for(now)
      until_at = Rails.cache.read(BLOCK_KEY).to_f
      remaining = (until_at - now.to_f).ceil
      remaining.positive? ? remaining : 0
    end
  end
end
