require_relative "fake_hackatime"

module HackatimeHelper
  SECRET_TOKEN = "tok-secret-access-0123456789".freeze
  SECRET_REFRESH = "tok-secret-refresh-0123456789".freeze

  def start_fake_hackatime
    @fake_hackatime = FakeHackatime.new
    @original_hackatime_url = Rails.configuration.x.hackatime.base_url
    Rails.configuration.x.hackatime.base_url = @fake_hackatime.url
    @fake_hackatime
  end

  def stop_fake_hackatime
    Rails.configuration.x.hackatime.base_url = @original_hackatime_url if @original_hackatime_url
    @fake_hackatime&.stop
  end

  def connect_hackatime(user, uid: "4242", access_token: SECRET_TOKEN, refresh_token: nil, expires_at: nil, **attributes)
    HackatimeConnection.create!({ user: user, hackatime_uid: uid, access_token: access_token, refresh_token: refresh_token,
                                  expires_at: expires_at, scopes: "profile read", connected_at: Time.current }.merge(attributes))
  end

  # Makes Rails.env.production? true for the block (Minitest 6 no longer ships stub).
  def as_production
    original = Rails.method(:env)
    Rails.define_singleton_method(:env) { ActiveSupport::EnvironmentInquirer.new("production") }
    yield
  ensure
    Rails.define_singleton_method(:env, original)
  end

  # Runs the block with Rails.logger writing to a string, and returns everything it logged.
  def capture_logs
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end
end
