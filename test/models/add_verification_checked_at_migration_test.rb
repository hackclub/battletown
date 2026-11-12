require "test_helper"
require Rails.root.join("db/migrate/20261113090001_add_verification_checked_at_to_users")

# The migration that records when verification was last copied from Hack Club Auth. Run inside the test transaction
# (PostgreSQL DDL is transactional), so the column is back as it was when the test ends.
class AddVerificationCheckedAtMigrationTest < ActiveSupport::TestCase
  setup { @migration = AddVerificationCheckedAtToUsers.new }

  def migrate(direction) = ActiveRecord::Migration.suppress_messages { @migration.public_send(direction) }

  def insert_user(uid, created_at:, updated_at:)
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL.squish)
      INSERT INTO users (hca_uid, created_at, updated_at, signed_up_on)
      VALUES (#{connection.quote(uid)}, #{connection.quote(created_at)}, #{connection.quote(updated_at)}, '2026-01-01')
    SQL
  end

  test "existing rows are backfilled from updated_at, the column is required and new rows default to now" do
    migrate(:down)
    User.reset_column_information
    assert_not_includes User.column_names, "verification_checked_at"
    insert_user("ident!old", created_at: Time.utc(2026, 3, 1), updated_at: Time.utc(2026, 5, 7, 8))
    insert_user("ident!older", created_at: Time.utc(2026, 1, 2), updated_at: Time.utc(2026, 1, 2))

    migrate(:up)
    User.reset_column_information

    assert_equal Time.utc(2026, 5, 7, 8), User.find_by!(hca_uid: "ident!old").verification_checked_at
    assert_equal Time.utc(2026, 1, 2), User.find_by!(hca_uid: "ident!older").verification_checked_at
    users(:onboarded).then { |user| assert_equal user.updated_at, user.reload.verification_checked_at }
    column = User.columns_hash.fetch("verification_checked_at")
    assert_not column.null
    assert_predicate column.default_function, :present?

    insert_user("ident!after", created_at: Time.current, updated_at: Time.current)
    # The column default is the DATABASE's clock (the same transaction time here), so compare with that, not this process's clock.
    assert_in_delta ActiveRecord::Base.connection.select_value("SELECT now()"), User.find_by!(hca_uid: "ident!after").verification_checked_at, 60
  end

  test "running the backfill again leaves checked times alone" do
    before = users(:onboarded).verification_checked_at
    ActiveRecord::Migration.suppress_messages { @migration.backfill }
    assert_equal before, users(:onboarded).reload.verification_checked_at
  end
end
