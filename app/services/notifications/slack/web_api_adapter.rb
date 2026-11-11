require "net/http"
require "json"

module Notifications
  module Slack
    # Sends a DM through the Slack Web API (https://api.slack.com/methods/chat.postMessage).
    #
    # A Slack user id (U... / W...) is a valid `channel` for chat.postMessage: Slack delivers the message into the
    # bot's direct message with that user, so no conversations.open call is needed. Required bot token scope:
    #   - chat:write   (post messages as the bot). That is the only scope this adapter uses.
    #   - im:write     is NOT needed; it would only be needed if we switched to conversations.open.
    # The user must be in the same workspace as the bot. Rate limit: chat.postMessage is "special tier" (about one
    # message per second per channel), plenty for one reminder per user per day.
    #
    # The bot token comes from ENV["SLACK_BOT_TOKEN"] at call time. It is sent only in the Authorization header and is
    # never logged, returned, or placed in an error code. Error codes returned from here are short allowlisted snake
    # case strings: exception messages and response bodies are never copied into a Result.
    class WebApiAdapter < Adapter
      ENDPOINT = "https://slack.com/api/chat.postMessage".freeze
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 5
      WRITE_TIMEOUT = 5
      MAX_RETRY_AFTER = 3600
      DEFAULT_RETRY_AFTER = 30
      CODE_FORMAT = /\A[a-z0-9_]{1,40}\z/

      # Slack `error` values that are worth trying again later.
      RETRYABLE = %w[ratelimited rate_limited internal_error fatal_error service_unavailable request_timeout
                     accesslimited].freeze
      # Credentials/setup problems: not the recipient's fault, so the dispatcher stops the whole run.
      SYSTEMIC = %w[invalid_auth not_authed token_revoked token_expired account_inactive missing_scope
                    no_permission org_login_required team_access_not_granted access_denied].freeze
      # Recipient problems that will not fix themselves: channel_not_found, user_not_found, user_disabled,
      # cannot_dm_bot, is_archived, msg_too_long, no_text ... Anything unlisted is treated as permanent as well, so an
      # unknown error never causes a retry storm.

      NETWORK_ERRORS = [ Timeout::Error, SocketError, IOError, EOFError, SystemCallError, OpenSSL::SSL::SSLError,
                         Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout ].freeze

      def initialize(token: nil, endpoint: ENDPOINT)
        @token = token
        @uri = URI.parse(endpoint)
        raise ArgumentError, "Slack endpoint must use https" unless @uri.is_a?(URI::HTTPS)
      end

      def delivers? = true

      def deliver_dm(slack_id:, text:)
        token = @token.presence || ENV["SLACK_BOT_TOKEN"].presence
        return Result.failure("missing_token", retryable: false, systemic: true) unless token
        return Result.failure("missing_recipient", retryable: false) if slack_id.blank?

        response = post(token, slack_id, text)
        interpret(response)
      rescue *NETWORK_ERRORS
        Result.failure("network_error", retryable: true)
      end

      private

      def post(token, slack_id, text)
        request = Net::HTTP::Post.new(@uri.request_uri)
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json; charset=utf-8"
        request.body = JSON.generate(channel: slack_id, text: text, unfurl_links: false, unfurl_media: false)

        Net::HTTP.start(@uri.host, @uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT,
                        read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT) do |http|
          http.request(request)
        end
      end

      def interpret(response)
        status = response.code.to_i
        return Result.failure("ratelimited", retryable: true, retry_after: retry_after(response)) if status == 429
        return Result.failure("http_error", retryable: true) if status >= 500
        return Result.failure("http_error", retryable: false) unless status == 200

        body = parse(response.body)
        return Result.failure("bad_response", retryable: true) unless body
        return Result.success if body["ok"] == true

        failure_for(sanitize(body["error"]), response)
      end

      def failure_for(code, response)
        if RETRYABLE.include?(code)
          Result.failure(code, retryable: true, retry_after: retry_after(response))
        elsif SYSTEMIC.include?(code)
          Result.failure(code, retryable: false, systemic: true)
        else
          Result.failure(code, retryable: false)
        end
      end

      def parse(raw)
        body = JSON.parse(raw.to_s)
        body if body.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      # Only well-formed short codes are kept, so nothing free-form from a response can reach the database or logs.
      def sanitize(code)
        code.is_a?(String) && CODE_FORMAT.match?(code) ? code : "unknown_error"
      end

      def retry_after(response)
        seconds = response["retry-after"].to_i
        seconds = DEFAULT_RETRY_AFTER unless seconds.positive?
        seconds.clamp(1, MAX_RETRY_AFTER)
      end
    end
  end
end
