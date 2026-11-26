require "net/http"
require "json"

module DevSimulator
  # The ids of the members of one Slack channel, for `bin/rails dev:slack_players` (DevSimulator::SlackSample). Development helper only.
  #
  # Needs the bot scope `channels:read` (public channels; `groups:read` for a private one) on top of the `users:read` the app already has:
  # conversations.members and conversations.list both ask for it. Without it Slack answers `missing_scope` and the task says so; the
  # alternative is to write the ids into tmp/dev_slack/members.json by hand (SlackSample reads that first). The token comes from
  # ENV["SLACK_BOT_TOKEN"], goes only in the Authorization header, and is never printed or kept; an error is a short allowlisted code.
  class SlackMembers
    class Failed < StandardError; end

    API = "https://slack.com/api/".freeze
    CODE_FORMAT = /\A[a-z0-9_]{1,40}\z/
    CHANNEL_ID_FORMAT = /\A[CG][A-Z0-9]{5,20}\z/
    PAGE_LIMIT = 200
    MAX_PAGES = 25

    def self.call(channel, **options) = new(**options).call(channel)

    # `http` is a callable `(method_name, params) -> parsed JSON Hash` (a stub in the tests).
    def initialize(token: ENV["SLACK_BOT_TOKEN"], http: nil)
      @token = token.to_s
      @http = http || method(:request)
    end

    # The member ids of a channel given by id ("C0123456789") or name ("ambers-mountain").
    def call(channel)
      raise Failed, "no_token" if @token.empty? && @http.is_a?(Method)

      id = channel.to_s.match?(CHANNEL_ID_FORMAT) ? channel.to_s : find_channel(channel.to_s.delete_prefix("#"))
      paged("conversations.members", { channel: id }) { |body| body["members"] }
    end

    private

    def find_channel(name)
      raise Failed, "channel_not_found" if name.empty?

      found = nil
      paged("conversations.list", { types: "public_channel,private_channel", exclude_archived: true }) do |body|
        found ||= body["channels"]&.find { |channel| channel["name"] == name }
        []
      end
      raise Failed, "channel_not_found" unless found && found["id"].to_s.match?(CHANNEL_ID_FORMAT)

      found["id"]
    end

    def paged(method_name, params)
      items = []
      cursor = nil
      MAX_PAGES.times do
        body = @http.call(method_name, params.merge(limit: PAGE_LIMIT, cursor: cursor).compact)
        raise Failed, code(body["error"]) unless body.is_a?(Hash) && body["ok"] == true

        items.concat(Array(yield(body)))
        cursor = body.dig("response_metadata", "next_cursor").presence
        break unless cursor
      end
      items.grep(String).uniq
    end

    def request(method_name, params)
      uri = URI.join(API, method_name)
      uri.query = URI.encode_www_form(params)
      request = Net::HTTP::Get.new(uri.request_uri)
      request["Authorization"] = "Bearer #{@token}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 10) { |http| http.request(request) }
      raise Failed, (response.code.to_i == 429 ? "ratelimited" : "http_error") unless response.code.to_i == 200

      JSON.parse(response.body.to_s.first(2_000_000))
    rescue JSON::ParserError
      raise Failed, "bad_response"
    rescue *Notifications::Slack::WebApiAdapter::NETWORK_ERRORS
      raise Failed, "network_error"
    end

    def code(value) = (value.is_a?(String) && value.match?(CODE_FORMAT) ? value : "unknown_error")
  end
end
