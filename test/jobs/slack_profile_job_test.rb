require "test_helper"
require_relative "../support/slack_profiles_helper"

class SlackProfileJobTest < ActiveJob::TestCase
  include SlackProfilesHelper

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown { Rails.cache = @original_cache }

  test "runs the refresh for the person" do
    user = slack_player
    with_bot_token { with_network(slack_router) { SlackProfileJob.perform_now(user.id) } }
    assert SlackProfile.find_by!(user_id: user.id).picture?
  end

  test "a missing person is ignored and a failure never raises" do
    assert_nothing_raised { SlackProfileJob.perform_now(0) }
    user = slack_player
    stub_method(SlackProfiles::Refresh, :call, ->(*, **) { raise "boom" }) { assert_nothing_raised { SlackProfileJob.perform_now(user.id) } }
  end

  test "a rate limit puts the job back after Retry-After, a few times at most" do
    user = slack_player
    limited = StreamResponse = SlackProfilesHelper::StreamResponse.new(429, "", "retry-after" => "20")
    with_bot_token do
      with_network(slack_router(info: limited)) do
        assert_enqueued_with(job: SlackProfileJob, args: [ user.id, 2 ]) { SlackProfileJob.perform_now(user.id) }
      end
    end
  end
end
