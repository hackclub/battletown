require "test_helper"

# Every player has a profile (no opt-in, no opt-out): an opaque unique address from the day the account is made, and a name that is the
# chosen display name, else the Slack name, else a generated handle, never the real name.
class PublicProfileTest < ActiveSupport::TestCase
  setup { @user = users(:onboarded) }

  test "every user has an address, made when the account is made and kept" do
    created = User.create!(hca_uid: "ident!fresh-one")
    assert_match(/\A[a-z0-9]{11}\z/, created.public_slug)
    slug = created.public_slug
    created.update!(profile_name: "Fresh", display_name: "Somebody Else")
    assert_equal slug, created.reload.public_slug
    assert_match(/\A[a-z0-9]{10,12}\z/, @user.public_slug)
  end

  test "there is no visibility switch any more" do
    assert_not_includes User.column_names, "profile_visible"
    %i[profile_visible? enable_profile! disable_profile! profile_visible_to? default_profile_name].each { |name| assert_not_respond_to @user, name }
    assert_not_respond_to User, :visible_by_slug
  end

  test "an address is required and the database refuses a user without one" do
    user = User.new(hca_uid: "ident!noslug")
    user.public_slug = nil
    assert user.valid?, "a new user is given an address before validation"
    assert_not_nil user.public_slug
    sql = "INSERT INTO users (hca_uid, signed_up_on, created_at, updated_at) VALUES ('ident!rawnoslug', CURRENT_DATE, now(), now())"
    assert_raises(ActiveRecord::NotNullViolation) { User.transaction(requires_new: true) { User.connection.execute(sql) } }
    @user.public_slug = nil
    assert_not @user.valid?
    assert @user.errors.include?(:public_slug)
  end

  test "addresses are unique, in the model and in the database" do
    other = users(:new_user)
    other.public_slug = @user.public_slug
    assert_not other.valid?
    assert other.errors.include?(:public_slug)
    assert_raises(ActiveRecord::RecordNotUnique) do
      User.transaction(requires_new: true) { other.update_columns(public_slug: @user.public_slug) }
    end
  end

  test "many new users get different addresses" do
    slugs = Array.new(25) { |index| User.create!(hca_uid: "ident!many#{index}").public_slug }
    assert_equal slugs.size, slugs.uniq.size
  end

  test "the shown name: the chosen display name, else the Slack name, else a generated handle" do
    handle = PublicProfile.handle_for(@user.public_slug)
    assert_equal handle, @user.public_name
    assert_equal handle, @user.fallback_name
    assert_no_match(/Veteran/, handle, "the real name is never used")
    SlackProfile.create!(user_id: @user.id, display_name: "Slacky")
    assert_equal "Slacky", @user.public_name, "a new row means 'use my Slack name and picture' is on"
    @user.update!(profile_name: "Chosen")
    assert_equal "Chosen", @user.public_name, "a name they typed wins over Slack's"
    assert_equal "Slacky", @user.fallback_name
    @user.update!(profile_name: "  ")
    assert_nil @user.profile_name
    assert_equal "Slacky", @user.public_name
    SlackProfile.find_by!(user_id: @user.id).update!(use_name: false)
    assert_equal handle, @user.public_name, "turned off: the Slack name is not used"
  end

  test "a Slack name that could pass for the team is not shown" do
    SlackProfile.create!(user_id: @user.id, display_name: "Hack Club Staff")
    assert_equal PublicProfile.handle_for(@user.public_slug), @user.public_name
  end

  test "a Slack name must pass the rules a typed name does: format, not an address, not the team's words, at most 30 characters" do
    handle = PublicProfile.handle_for(@user.public_slug)
    [ "free-nitro.com", "evil.com", "@someone", "\u{1F600}\u{1F600}\u{1F600}", "<b>x</b>", "a/b", "-leading", "Hack Club Staff" ].each do |bad|
      SlackProfile.where(user_id: @user.id).delete_all
      SlackProfile.create!(user_id: @user.id, display_name: bad)
      assert_equal handle, @user.reload.public_name, "#{bad.inspect} must not be shown"
      assert_equal handle, @user.fallback_name, bad.inspect
    end
    [ "Maya", "Maya K.", "Jean-Luc", "o'Neil", "Zoë" ].each do |good|
      SlackProfile.where(user_id: @user.id).delete_all
      SlackProfile.create!(user_id: @user.id, display_name: good)
      assert_equal good, @user.reload.public_name, good.inspect
    end
  end

  test "the generated handle is stable, never a real name, and always a valid name" do
    assert_equal PublicProfile.handle_for("abcdefghijk"), PublicProfile.handle_for("abcdefghijk")
    assert_equal "Player", PublicProfile.handle_for(nil)
    names = Array.new(200) { |index| PublicProfile.handle_for(SecureRandom.alphanumeric(11).downcase + index.to_s) }
    assert_operator names.uniq.size, :>, 100
    names.each do |name|
      assert_match PublicProfile::NAME_FORMAT, name
      assert_operator name.length, :<=, PublicProfile::NAME_MAX
      assert_not PublicProfile.reserved_name?(name), name
    end
  end

  test "a name that could pass for the team or the app is refused, but ordinary names that only contain those letters are fine" do
    [ "Hack Club", "hackclub", "Hack-Club Staff", "Staff", "the admin", "Moderator Mo", "Battletown", "battle_town", "Administrator" ].each do |reserved|
      @user.profile_name = reserved
      assert_not @user.valid?, "#{reserved.inspect} should be refused"
      assert @user.errors.include?(:profile_name), reserved.inspect
    end
    [ "Padmini", "Adminah", "Stafford", "Hacker Ada", "Clubber" ].each do |fine|
      @user.profile_name = fine
      assert @user.valid?, "#{fine.inspect}: #{@user.errors.full_messages}"
    end
  end

  test "names: letters, numbers, spaces and . _ - ' only, 1 to 30 characters, nothing that looks like a web address" do
    [ "Ada", "Ada L.", "o'Neil", "user_01", "Jean-Luc", "Zoë", "日本語" ].each do |good|
      @user.profile_name = good
      assert @user.valid?, "#{good.inspect}: #{@user.errors.full_messages}"
    end
    [ "a@b", "<b>x</b>", "x/y", "https://evil.com", "evil.com", "Visit hack.club", "emoji \u{1F600}", "-leading", "a" * 31, "semi;colon", "tab\tname!" ].each do |bad|
      @user.profile_name = bad
      assert_not @user.valid?, "#{bad.inspect} should be refused"
      assert @user.errors.include?(:profile_name), bad.inspect
    end
  end

  test "a blank name is no name" do
    @user.profile_name = "   "
    assert_nil @user.profile_name
    assert @user.valid?
  end

  test "by_slug finds any player, and an unknown or malformed address finds nothing" do
    assert_equal @user, User.by_slug(@user.public_slug)
    assert_nil User.by_slug("nope")
    assert_nil User.by_slug(nil)
    assert_nil User.by_slug("a' OR '1'='1")
    assert_nil User.by_slug("abcdefghijk")
  end

  test "the database refuses an overlong name and an empty one" do
    [ "", "x" * 31 ].each do |value|
      sql = "UPDATE users SET profile_name = #{User.connection.quote(value)} WHERE id = #{@user.id}"
      assert_raises(ActiveRecord::StatementInvalid) { User.transaction(requires_new: true) { User.connection.execute(sql) } }
    end
  end
end
