require "test_helper"

class PlinkoPlayersTest < ActiveSupport::TestCase
  setup do
    @user = users(:onboarded)
    @config = Plinko::Config.current
  end

  test "the first call makes a player with the leaderboard off and a nickname from the word lists" do
    player = Plinko::Players.for(@user)
    assert_not player.leaderboard_opt_in
    adjective, animal, number = player.nickname.split
    assert_includes @config.nickname_adjectives, adjective
    assert_includes @config.nickname_animals, animal
    assert_includes 10..99, number.to_i
    assert_equal player, Plinko::Players.for(@user), "asking again does not make a second row"
    assert_equal 1, PlinkoPlayer.where(user_id: @user.id).count
  end

  test "a nickname is never derived from the real name" do
    user = User.create!(hca_uid: "plinko-name-#{SecureRandom.hex(3)}", display_name: "Zebediah Quarrington", email: "zeb@example.com")
    20.times do
      nickname = Plinko::Nicknames.generate
      assert_no_match(/zebediah|quarrington|zeb/i, nickname)
    end
    assert_no_match(/zebediah|quarrington/i, Plinko::Players.for(user).nickname)
  end

  test "regenerating gives a different nickname" do
    player = Plinko::Players.for(@user)
    before = player.nickname
    5.times { assert_not_equal before, Plinko::Players.regenerate!(@user).nickname }
  end

  test "nicknames are unique, even when the lists are tiny" do
    tiny = @config.with(nickname_adjectives: %w[Calm Bold], nickname_animals: %w[Otter Fox])
    names = Array.new(8) { Plinko::Nicknames.generate(config: tiny).tap { |name| PlinkoPlayer.create!(user: User.create!(hca_uid: "tiny-#{SecureRandom.hex(4)}"), nickname: name) } }
    assert_equal names.size, names.map(&:downcase).uniq.size
  end

  test "two players cannot hold the same nickname, whatever the case" do
    other = User.create!(hca_uid: "plinko-dupe-#{SecureRandom.hex(3)}")
    PlinkoPlayer.create!(user: @user, nickname: "Calm Otter 11")
    assert_not PlinkoPlayer.new(user: other, nickname: "calm otter 11").valid?
    assert_raises(ActiveRecord::RecordNotUnique) { PlinkoPlayer.new(user: other, nickname: "CALM OTTER 11").save!(validate: false) }
  end

  test "opting in and out" do
    assert Plinko::Players.opt_in!(@user, true).leaderboard_opt_in
    assert_not Plinko::Players.opt_in!(@user, false).leaderboard_opt_in
  end

  test "the word lists are plain, unique words and the config refuses anything else" do
    assert @config.nickname_adjectives.size >= 20
    assert @config.nickname_animals.size >= 20
    base = Rails.application.config_for(:game).fetch(:plinko)
    assert_raises(ArgumentError) { Plinko::Config.from_hash(base.merge(nickname_animals: [ "Otter", "Otter" ])) }
    assert_raises(ArgumentError) { Plinko::Config.from_hash(base.merge(nickname_animals: [ "Otter", "Fox 7" ])) }
  end
end
