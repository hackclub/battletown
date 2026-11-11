require "net/http"
require "json"

module Notifications
  module Slack
    # Asks Slack who a bot token belongs to (https://api.slack.com/methods/auth.test) so the owner can confirm the app
    # is set up as config/slack/manifest.yml describes, without sending a message. Used by `bin/rails slack:check`.
    #
    # The token is only sent in the Authorization header. It is never returned or printed: the Report holds the
    # workspace name, the bot's name, the granted scopes and plain-language problems, and nothing else from the response.
    class Check
      ENDPOINT = "https://slack.com/api/auth.test".freeze
      # Keep in step with oauth_config.scopes.bot in config/slack/manifest.yml (a test compares them).
      EXPECTED_SCOPES = %w[chat:write].freeze
      CODE_FORMAT = /\A[a-z0-9_]{1,40}\z/

      Report = Struct.new(:ok, :team, :user, :scopes, :problems, keyword_init: true) do
        def ok? = ok
      end

      def initialize(token: nil, endpoint: ENDPOINT)
        @token = token
        @uri = URI.parse(endpoint)
        raise ArgumentError, "Slack endpoint must use https" unless @uri.is_a?(URI::HTTPS)
      end

      def call
        token = @token.presence || ENV["SLACK_BOT_TOKEN"].presence
        return failure("SLACK_BOT_TOKEN is not set.") unless token

        response = post(token)
        return failure("Slack answered with HTTP status #{response.code.to_i}.") unless response.code.to_i == 200

        body = parse(response.body)
        return failure("Slack sent a response that could not be read.") unless body
        return failure("Slack rejected the token (error: #{sanitize_code(body["error"])}).") unless body["ok"] == true

        build_report(body, response["x-oauth-scopes"])
      rescue *WebApiAdapter::NETWORK_ERRORS
        failure("Could not reach Slack (network error). Try again.")
      end

      private

      def post(token)
        request = Net::HTTP::Post.new(@uri.request_uri)
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/x-www-form-urlencoded"

        Net::HTTP.start(@uri.host, @uri.port, use_ssl: true, open_timeout: WebApiAdapter::OPEN_TIMEOUT,
                        read_timeout: WebApiAdapter::READ_TIMEOUT, write_timeout: WebApiAdapter::WRITE_TIMEOUT) do |http|
          http.request(request)
        end
      end

      def build_report(body, scopes_header)
        scopes = scopes_header.present? ? scopes_header.split(",").map(&:strip).compact_blank.sort : nil
        problems = []
        problems << "This is not a bot token (use the Bot User OAuth Token, which starts with xoxb-)." if body["bot_id"].blank?
        problems.concat(scope_problems(scopes)) if scopes
        Report.new(ok: problems.empty?, team: clean(body["team"]), user: clean(body["user"]), scopes: scopes, problems: problems)
      end

      def scope_problems(scopes)
        problems = []
        extra = scopes - EXPECTED_SCOPES
        missing = EXPECTED_SCOPES - scopes
        problems << "Unexpected scopes: #{extra.join(", ")}. Only #{EXPECTED_SCOPES.join(", ")} is approved." if extra.any?
        problems << "Missing scopes: #{missing.join(", ")}." if missing.any?
        problems
      end

      def failure(message)
        Report.new(ok: false, team: nil, user: nil, scopes: nil, problems: [ message ])
      end

      def parse(raw)
        body = JSON.parse(raw.to_s)
        body if body.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def sanitize_code(code)
        code.is_a?(String) && CODE_FORMAT.match?(code) ? code : "unknown_error"
      end

      # Names come from Slack; strip anything unprintable and cap the length before it reaches a terminal.
      def clean(value)
        value.to_s.gsub(/[^[:print:]]/, "").first(80)
      end
    end
  end
end
