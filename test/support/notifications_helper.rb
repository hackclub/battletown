require "net/http"
require "stringio"

# Shared helpers for the notification tests. No test here may reach the network: Net::HTTP.start is always stubbed.
module NotificationsHelper
  TOKEN = "xoxb-TEST-TOKEN-1234567890".freeze

  # Records deliveries and answers from a queue of Results (the last one repeats; default is success).
  class FakeAdapter < Notifications::Slack::Adapter
    attr_reader :calls

    def initialize(*results, delivers: true)
      @results = results
      @calls = []
      @delivers = delivers
    end

    def delivers? = @delivers

    def deliver_dm(slack_id:, text:)
      @calls << { slack_id: slack_id, text: text }
      @results.size > 1 ? @results.shift : (@results.first || Notifications::Slack::Result.success)
    end
  end

  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](name) = (headers || {})[name.to_s.downcase]
  end

  class FakeHttp
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def request(request)
      @requests << request
      @response
    end
  end

  def with_env(vars)
    original = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_rails_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  # Stubs Net::HTTP.start. Yields a hash of what the adapter asked for; `error` makes the call raise instead.
  def stub_http(response: nil, error: nil)
    seen = { starts: [] }
    http = FakeHttp.new(response)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, **options, &block|
      seen[:starts] << { host: host, port: port, options: options }
      raise error if error

      block.call(http)
    end
    seen[:http] = http
    yield seen
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def capture_logs
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def json_response(body, code: "200", headers: {})
    FakeResponse.new(code, body.is_a?(String) ? body : JSON.generate(body), headers)
  end

  # A committed-in-transaction onboarded user with a schedule; tweak with overrides.
  def create_user(suffix = SecureRandom.hex(4), **attrs)
    User.create!({ hca_uid: "ident!#{suffix}", slack_id: "U#{suffix.upcase}", onboarded_at: Time.utc(2026, 11, 1),
                   onboarding_step: 4, coding_days: 127, coding_time: "18:30", time_zone: "UTC" }.merge(attrs))
  end
end
