require "test_helper"
require_relative "../../support/hackatime_helper"

module Hackatime
  # Real threads need real, committed rows and separate database connections, so this class opts out of
  # transactional tests and cleans up after itself.
  class ClientConcurrencyTest < ActiveSupport::TestCase
    include HackatimeHelper

    self.use_transactional_tests = false

    setup { @fake = start_fake_hackatime }

    teardown do
      stop_fake_hackatime
      HackatimeConnection.delete_all
    end

    test "two callers racing on an expired token cause exactly one refresh" do
      @fake.on("POST", "/oauth/token") do |_req|
        sleep 0.3 # long enough that the second caller reaches the row lock while the first holds it
        [ 200, { "access_token" => "new-access", "expires_in" => 3600 } ]
      end
      @fake.on("GET", "/x") { |_req| [ 200, { "ok" => true } ] }
      connection = connect_hackatime(users(:onboarded), refresh_token: SECRET_REFRESH, expires_at: 1.hour.ago)

      threads = 2.times.map do
        Thread.new do
          Thread.current.report_on_exception = false
          ActiveRecord::Base.connection_pool.with_connection do
            Client.new(HackatimeConnection.find(connection.id), base_url: @fake.url, client_id: "cid", client_secret: "csecret").get_json("/x")
          end
        end
      end
      threads.each(&:value)

      assert_equal 1, @fake.requests_for("POST", "/oauth/token").size, "the second caller must see the fresh token, not refresh again"
      assert_equal [ "Bearer new-access" ] * 2, @fake.requests_for("GET", "/x").map { |r| r.headers["authorization"] }
      assert_equal "new-access", connection.reload.access_token
    end
  end
end
