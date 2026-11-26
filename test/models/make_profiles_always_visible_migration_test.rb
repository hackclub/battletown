require "test_helper"
require Rails.root.join("db/migrate/20261126160000_make_profiles_always_visible")

# The migration that gives every user an address and drops the visibility column. Run inside the test transaction (PostgreSQL DDL is
# transactional), so the schema is back as it was when the test ends.
class MakeProfilesAlwaysVisibleMigrationTest < ActiveSupport::TestCase
  setup { @migration = MakeProfilesAlwaysVisible.new }

  # A statement prepared against the changed table must not fail the next test on this worker ("cached plan must not change result type").
  teardown do
    User.reset_column_information
    ActiveRecord::Base.connection_pool.connections.each(&:clear_cache!)
  end

  def migrate(direction) = ActiveRecord::Migration.suppress_messages { @migration.public_send(direction) }

  def insert_user(uid, slug: nil)
    connection = ActiveRecord::Base.connection
    connection.execute("INSERT INTO users (hca_uid, public_slug, created_at, updated_at, signed_up_on) " \
                       "VALUES (#{connection.quote(uid)}, #{connection.quote(slug)}, now(), now(), '2026-01-01')")
  end

  test "up gives every user without an address a unique one, keeps the ones that exist, and makes the address required" do
    migrate(:down)
    User.reset_column_information
    assert_includes User.column_names, "profile_visible"
    keep = users(:onboarded).public_slug
    30.times { |index| insert_user("ident!backfill#{index}") }
    insert_user("ident!hasone", slug: "alreadyhere1")
    users(:new_user).update_columns(public_slug: nil)

    migrate(:up)
    User.reset_column_information

    slugs = User.pluck(:public_slug)
    assert slugs.none?(&:nil?)
    assert_equal slugs.size, slugs.uniq.size, "every address is different"
    assert(slugs.all? { |slug| slug.match?(PublicProfile::SLUG_FORMAT) })
    assert_equal keep, users(:onboarded).reload.public_slug, "an existing address is never changed"
    assert_equal "alreadyhere1", User.find_by!(hca_uid: "ident!hasone").public_slug
    assert_not User.columns_hash.fetch("public_slug").null
    assert_not_includes User.column_names, "profile_visible"
    assert_raises(ActiveRecord::NotNullViolation) do
      User.transaction(requires_new: true) { insert_user("ident!after") }
    end
    assert_raises(ActiveRecord::RecordNotUnique) do
      User.transaction(requires_new: true) { insert_user("ident!dup", slug: "alreadyhere1") }
    end
  end

  test "up drops the check constraint that tied visibility to a name, and keeps the name rules" do
    constraints = ActiveRecord::Base.connection.check_constraints(:users).map(&:name)
    assert_not_includes constraints, "users_profile_visible_needs_identity_check"
    assert_includes constraints, "users_profile_name_length_check"
    default = ActiveRecord::Base.connection.columns(:slack_profiles).to_h { |column| [ column.name, column.default ] }
    assert_equal "true", default["use_name"]
    assert_equal "true", default["use_picture"]
  end

  test "down puts the column and constraint back with nobody visible, lets the address be empty again, and up works again afterwards" do
    migrate(:down)
    User.reset_column_information
    assert_includes User.column_names, "profile_visible"
    assert User.columns_hash.fetch("public_slug").null
    assert_equal 0, User.where(profile_visible: true).count
    assert_includes ActiveRecord::Base.connection.check_constraints(:users).map(&:name), "users_profile_visible_needs_identity_check"
    default = ActiveRecord::Base.connection.columns(:slack_profiles).to_h { |column| [ column.name, column.default ] }
    assert_equal "false", default["use_name"]

    migrate(:up)
    User.reset_column_information
    assert_not_includes User.column_names, "profile_visible"
    assert_not User.columns_hash.fetch("public_slug").null
  end
end
