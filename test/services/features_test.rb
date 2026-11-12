require "test_helper"

class FeaturesTest < ActiveSupport::TestCase
  test "every known flag is off until switched on" do
    assert_equal %i[team quests returning plinko ship_screenshots merch_track email nps eligibility_gate].sort, Features::NAMES.sort
    Features::NAMES.each { |name| assert_not Features.enabled?(name), "#{name} must ship off" }
  end

  test "flipping a flag changes only that flag, and names may be strings" do
    Flipper.enable(:team)
    assert Features.enabled?(:team)
    assert Features.enabled?("team")
    assert_not Features.enabled?(:quests)
    Flipper.disable(:team)
    assert_not Features.enabled?(:team)
  end

  test "an unknown name raises so a typo fails loudly" do
    error = assert_raises(ArgumentError) { Features.enabled?(:tem) }
    assert_includes error.message, "unknown feature :tem"
    assert_raises(ArgumentError) { Features.validate!(nil) }
  end

  test "the admins group lets staff dogfood a flag before it is on for everyone" do
    admin = users(:onboarded)
    teen = users(:new_user)
    ENV["ADMIN_HCA_UIDS"] = admin.hca_uid
    Flipper.enable_group(:team, :admins)

    assert Features.enabled?(:team, admin)
    assert_not Features.enabled?(:team, teen)
    assert_not Features.enabled?(:team)
  ensure
    ENV.delete("ADMIN_HCA_UIDS")
  end

  test "a percentage gate is fine and an actor gives User a flipper_id" do
    assert_equal "User;#{users(:onboarded).id}", users(:onboarded).flipper_id
    Flipper.enable_percentage_of_actors(:quests, 100)
    assert Features.enabled?(:quests, users(:onboarded))
  end

  test "a flag that cannot be read counts as off" do
    original = Flipper.method(:enabled?)
    Flipper.define_singleton_method(:enabled?) { |*| raise ActiveRecord::StatementInvalid, "no such table" }
    assert_not Features.enabled?(:team)
    assert_raises(ArgumentError) { Features.enabled?(:tem) } # a typo still raises when the store is down
  ensure
    Flipper.define_singleton_method(:enabled?, original)
  end

  test "register_known! adds every flag, off, idempotently, and only once the tables exist" do
    assert_empty Flipper.features.to_a
    2.times { Features.register_known! }
    assert_equal Features::NAMES.map(&:to_s).sort, Flipper.features.map(&:key).sort
    Features::NAMES.each { |name| assert_not Features.enabled?(name) }

    Flipper.features.each(&:remove)
    connection = ActiveRecord::Base.connection
    connection.define_singleton_method(:data_source_exists?) { |*| false }
    Features.register_known!
    assert_empty Flipper.features.to_a
  ensure
    connection&.singleton_class&.remove_method(:data_source_exists?)
  end

  test "with_feature and without_feature set the flag for the block and restore it" do
    with_feature(:team) do
      assert Features.enabled?(:team)
      without_feature(:team) { assert_not Features.enabled?(:team) }
      assert Features.enabled?(:team)
    end
    assert_not Features.enabled?(:team)

    assert_raises(RuntimeError) { with_feature(:team) { raise "boom" } }
    assert_not Features.enabled?(:team), "the flag is restored even when the block raises"
    assert_raises(ArgumentError) { with_feature(:nope) { } }
  end

  test "flags do not leak between tests (first half)" do
    assert_not Features.enabled?(:plinko)
    Flipper.enable(:plinko)
  end

  test "flags do not leak between tests (second half)" do
    assert_not Features.enabled?(:plinko)
    Flipper.enable(:plinko)
  end
end
