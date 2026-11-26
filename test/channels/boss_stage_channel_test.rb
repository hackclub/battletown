require "test_helper"
require_relative "../support/fighters_helper"

class BossStageChannelTest < ActionCable::Channel::TestCase
  include FightersHelper

  setup do
    @user = users(:onboarded)
    @boss = make_boss(starts_on: friday_on_or_before(Time.current.utc.to_date))
    stub_connection current_user_id: @user.id
  end

  test "an onboarded player follows the stream of the current boss, the same one for everybody" do
    subscribe
    assert subscription.confirmed?
    assert_has_stream "boss_stage:#{@boss.id}"
  end

  test "it is turned away while the kill switch is on" do
    with_feature(:live_updates_paused) do
      subscribe
      assert subscription.rejected?
    end
  end

  test "it is turned away when there is no boss to follow" do
    @boss.destroy!
    subscribe
    assert subscription.rejected?
  end
end
