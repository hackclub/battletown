require "net/http"
require "vips"
require_relative "profiles_helper"
require_relative "notifications_helper"

# Builders and a fake network for the Slack profile tests. Nothing here reaches the network: Net::HTTP.start is replaced for the block, and
# every request (host, path, headers) is recorded.
module SlackProfilesHelper
  include ProfilesHelper
  include NotificationsHelper

  USER_SLACK_ID = "U0PLAYER01".freeze
  AVATAR_URL = "https://avatars.slack-edge.com/2026-11-01/123/abc_512.png".freeze

  # A response that can be streamed the way Net::HTTP does it (`request(req) { |response| response.read_body { |chunk| ... } }`).
  class StreamResponse
    attr_reader :code, :body, :headers

    def initialize(code, body, headers = {})
      @code = code.to_s
      @body = body
      @headers = headers.transform_keys { |key| key.to_s.downcase }
    end

    def [](name) = @headers[name.to_s.downcase]

    def read_body
      return @body unless block_given?

      @body.to_s.b.scan(/.{1,4096}/mn).each { |chunk| yield chunk }
    end
  end

  class Network
    attr_reader :requests, :starts

    def initialize(&router)
      @router = router
      @requests = []
      @starts = []
    end

    def start(host, port, options)
      @starts << { host: host, port: port, options: options }
      @current = host
    end

    def request(request, &block)
      @requests << { host: @current, path: request.path, authorization: request["Authorization"], method: request.method }
      response = @router.call(@current, request)
      block ? block.call(response) : response
      response
    end

    def hosts = @starts.map { |start| start[:host] }
    def calls_to(host) = @requests.select { |request| request[:host] == host }
  end

  # Replaces Net::HTTP.start. `router` (a lambda) gets (host, request) and returns a response (StreamResponse, or a NotificationsHelper FakeResponse).
  def with_network(router)
    network = Network.new(&router)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, **options, &block|
      network.start(host, port, options)
      block.call(network)
    end
    yield network
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  # A picture in memory: format :png, :jpeg, :webp or :gif, `size` px square, a plain colour.
  def picture_bytes(format = :png, size: 300, color: [ 220, 60, 90 ])
    image = Vips::Image.black(size, size, bands: 3).new_from_image(color)
    case format
    when :png then image.pngsave_buffer
    when :jpeg then image.jpegsave_buffer
    when :webp then image.webpsave_buffer
    when :gif then image.gifsave_buffer
    end
  end

  def users_info_body(name: "Maya", real_name: "Maya Real Name", custom: true, image: AVATAR_URL, extra: {})
    { ok: true, user: { id: USER_SLACK_ID, deleted: false, is_bot: false,
                        profile: { display_name: name, real_name: real_name, is_custom_image: custom, image_512: image, image_192: image }.merge(extra) } }
  end

  def slack_ok(**options) = StreamResponse.new(200, JSON.generate(users_info_body(**options)))
  def slack_error(code) = StreamResponse.new(200, JSON.generate(ok: false, error: code))

  # The usual Slack: slack.com answers users.info, any other host (the picture host) answers the picture.
  def slack_router(info: nil, picture: nil)
    info ||= slack_ok
    picture ||= StreamResponse.new(200, picture_bytes(:png), "content-type" => "image/png")
    ->(host, _request) { host == "slack.com" ? info : picture }
  end

  # A player with a Slack id. `use_slack: false` makes them one who turned "Use my Slack name and picture" off (the row says so); otherwise there
  # is a row with the default (on, nothing fetched yet). `name` is the display name they chose (nil: none).
  def slack_player(key = "p1", name: "Maya", use_slack: true)
    user = make_player(key, name: name)
    user.update_columns(slack_id: USER_SLACK_ID.sub("01", key.to_s.rjust(2, "0").upcase[0, 2]))
    SlackProfile.create!(user_id: user.id, use_name: use_slack, use_picture: use_slack)
    user.reload
  end

  def with_bot_token(token = TOKEN, &block) = with_env("SLACK_BOT_TOKEN" => token, &block)
end
