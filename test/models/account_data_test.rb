require "test_helper"

# Guards future features: any table that belongs to a user must cascade on delete and be exported.
class AccountDataTest < ActiveSupport::TestCase
  def connection = ActiveRecord::Base.connection

  test "the real schema and the export registry agree" do
    assert_empty AccountData.problems
  end

  test "every registered source points at a real model, table and user column" do
    AccountData.sources.each do |source|
      assert_equal source.table, source.model.table_name, source.key
      assert_includes source.model.column_names, source.user_column, source.key
    end
    assert_includes AccountData.sources.map(&:table), "users"
  end

  test "a table with a user foreign key but no cascade and no registry entry is flagged" do
    connection.create_table(:zz_notes) { |t| t.references :user, null: false, foreign_key: true }

    problems = AccountData.problems
    assert_includes problems, "zz_notes.user_id references users without on_delete: :cascade"
    assert_includes problems, "zz_notes references users but is not in AccountData::SOURCES"
  end

  test "a user_id column without any foreign key is flagged" do
    connection.create_table(:zz_loose) { |t| t.bigint :user_id }

    assert_includes AccountData.problems, "zz_loose.user_id has no foreign key to users"
  end

  test "a cascading, registered table passes" do
    connection.create_table(:zz_notes) { |t| t.references :user, null: false, foreign_key: { on_delete: :cascade } }
    source = AccountData::Source.new(key: "notes", table: "zz_notes", model_name: "User", user_column: "id", except: [])

    assert_empty AccountData.problems(sources: AccountData.sources + [ source ])
  end

  test "deleting a user removes rows in a cascading table (the database does it, not the app)" do
    connection.create_table(:zz_notes) { |t| t.references :user, null: false, foreign_key: { on_delete: :cascade } }
    user = users(:onboarded)
    other = users(:new_user)
    connection.execute("INSERT INTO zz_notes (user_id) VALUES (#{user.id}), (#{other.id})")

    AccountDeletion.call(user)

    assert_equal [ other.id ], connection.select_values("SELECT user_id FROM zz_notes")
  end
end
