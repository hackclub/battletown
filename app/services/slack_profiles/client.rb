require "net/http"
require "json"

module SlackProfiles
  # One call to Slack's users.info (https://api.slack.com/methods/users.info): the display name and the picture address of ONE member.
  # Bot scope needed: users:read (and nothing else: no email scope is ever requested). Tier 4, about 100 calls a minute, which
  # SlackProfiles::Gate keeps well under. The bot token comes from ENV["SLACK_BOT_TOKEN"] at call time and travels only in the
  # Authorization header: it is never logged, returned, or put into an error code. Error codes are short allowlisted snake_case strings
  # (the same rule as Notifications::Slack::WebApiAdapter): a response body or exception message is never copied anywhere.
  #
  # Never raises on a network or Slack problem: the Result says what happened.
  class Client
    ENDPOINT = "https://slack.com/api/users.info".freeze
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 5
    WRITE_TIMEOUT = 5
    MAX_RETRY_AFTER = 3600
    DEFAULT_RETRY_AFTER = 30
    CODE_FORMAT = /\A[a-z0-9_]{1,40}\z/
    SLACK_ID_FORMAT = /\A[UW][A-Z0-9]{2,20}\z/
    MAX_BODY_BYTES = 200_000

    # `name` is the raw Slack display name (never the real name: that is not the player's to show; sanitise it before use); `image_url` is the 512 px
    # picture address, only when the person uploaded one (nil for Slack's default picture); `retry_after` seconds on a 429.
    Result = Data.define(:ok, :error_code, :name, :image_url, :retry_after) do
      def ok? = ok
      def self.failure(code, retry_after: nil) = new(ok: false, error_code: code, name: nil, image_url: nil, retry_after: retry_after)
    end

    def initialize(token: nil, endpoint: ENDPOINT)
      @token = token
      @uri = URI.parse(endpoint)
      raise ArgumentError, "Slack endpoint must use https" unless @uri.is_a?(URI::HTTPS)
    end

    def user_info(slack_id)
      token = @token.presence || ENV["SLACK_BOT_TOKEN"].presence
      return Result.failure("no_token") unless token
      return Result.failure("not_found") unless slack_id.to_s.match?(SLACK_ID_FORMAT)

      interpret(get(token, slack_id))
    rescue *Notifications::Slack::WebApiAdapter::NETWORK_ERRORS
      Result.failure("network_error")
    end

    private

    def get(token, slack_id)
      uri = @uri.dup
      uri.query = URI.encode_www_form(user: slack_id)
      request = Net::HTTP::Get.new(uri.request_uri)
      request["Authorization"] = "Bearer #{token}"
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT) do |http|
        http.request(request)
      end
    end

    def interpret(response)
      status = response.code.to_i
      return Result.failure("ratelimited", retry_after: retry_after(response)) if status == 429
      return Result.failure("http_error") unless status == 200
      return Result.failure("bad_response") if response.body.to_s.bytesize > MAX_BODY_BYTES

      body = parse(response.body)
      return Result.failure("bad_response") unless body
      return Result.failure(sanitize(body["error"]), retry_after: (retry_after(response) if body["error"] == "ratelimited")) unless body["ok"] == true

      from_user(body["user"])
    end

    def from_user(user)
      return Result.failure("bad_response") unless user.is_a?(Hash) && user["profile"].is_a?(Hash)
      return Result.failure("not_found") if user["deleted"] == true || user["is_bot"] == true

      profile = user["profile"]
      # Only the display name the person chose for Slack. `real_name` (usually a full name) is never read: a blank display name stores
      # nothing, so the generated handle is shown.
      name = profile["display_name"].to_s.strip.presence
      image = profile["image_512"] if profile["is_custom_image"] == true && profile["image_512"].is_a?(String)
      Result.new(ok: true, error_code: nil, name: name, image_url: image, retry_after: nil)
    end

    def parse(raw)
      body = JSON.parse(raw.to_s)
      body if body.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    # Only a well-formed short code is kept, so nothing free-form from a response can reach the database or a log.
    def sanitize(code) = (code.is_a?(String) && CODE_FORMAT.match?(code) ? code : "unknown_error")

    def retry_after(response)
      seconds = response["retry-after"].to_i
      seconds = DEFAULT_RETRY_AFTER unless seconds.positive?
      seconds.clamp(1, MAX_RETRY_AFTER)
    end
  end
end
