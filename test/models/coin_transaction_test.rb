require "test_helper"
require_relative "../support/coins_helper"

class CoinTransactionTest < ActiveSupport::TestCase
  include CoinsHelper

  setup { @user = build_user }

  def attributes(overrides = {})
    { user_id: @user.id, amount: 10, kind: "ship_approval", idempotency_key: "k-#{SecureRandom.hex(4)}", created_at: Time.current }.merge(overrides)
  end

  def insert_sql(overrides = {})
    row = attributes(overrides)
    columns = row.keys.map { |c| ActiveRecord::Base.connection.quote_column_name(c) }.join(", ")
    values = row.values.map { |v| ActiveRecord::Base.connection.quote(v) }.join(", ")
    "INSERT INTO coin_transactions (#{columns}) VALUES (#{values})"
  end

  def rejected_by_database(overrides)
    assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::NotNullViolation, ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) { ActiveRecord::Base.connection.execute(insert_sql(overrides)) }
    end
  end

  test "a valid row is created and then read-only" do
    row = CoinTransaction.create!(user: @user, amount: 25, kind: "ship_approval", idempotency_key: "a", note: "ok", created_by: "ship_approval")
    assert row.readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(amount: 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.delete }
    assert_raises(ActiveRecord::ReadOnlyRecord) { CoinTransaction.find(row.id).update_column(:amount, 5) }
    assert_equal 25, CoinTransaction.find(row.id).amount
  end

  test "the model validates amount, kind, sign, key, note and created_by" do
    assert_not CoinTransaction.new(attributes(amount: 0)).valid?
    assert_not CoinTransaction.new(attributes(kind: "gift")).valid?
    assert_not CoinTransaction.new(attributes(kind: "purchase", amount: 5)).valid?
    assert_not CoinTransaction.new(attributes(kind: "ship_approval", amount: -5)).valid?
    assert_not CoinTransaction.new(attributes(idempotency_key: "")).valid?
    assert_not CoinTransaction.new(attributes(idempotency_key: "k" * 121)).valid?
    assert_not CoinTransaction.new(attributes(note: "n" * 201)).valid?
    assert_not CoinTransaction.new(attributes(created_by: "Amber Smith")).valid?
    assert_not CoinTransaction.new(attributes(reference_type: "Ship")).valid?
    assert CoinTransaction.new(attributes(kind: "adjustment", amount: -5)).valid?
  end

  test "raw SQL cannot insert a zero amount" do
    rejected_by_database(amount: 0)
  end

  test "raw SQL cannot insert an unknown kind" do
    rejected_by_database(kind: "gift")
  end

  test "raw SQL cannot insert the wrong sign for a kind" do
    rejected_by_database(kind: "purchase", amount: 5)
    rejected_by_database(kind: "refund", amount: -5)
    rejected_by_database(kind: "streak_bonus", amount: -1)
  end

  test "raw SQL cannot insert a half reference" do
    rejected_by_database(reference_type: "Ship")
    rejected_by_database(reference_id: 4)
  end

  test "raw SQL cannot insert an over-long or empty idempotency key, note, or bad created_by" do
    rejected_by_database(idempotency_key: "k" * 121)
    rejected_by_database(idempotency_key: "")
    rejected_by_database(note: "n" * 201)
    rejected_by_database(created_by: "Has Spaces And Caps")
  end

  test "raw SQL cannot insert without a user or for a user that does not exist" do
    rejected_by_database(user_id: nil)
    rejected_by_database(user_id: User.maximum(:id) + 1000)
  end

  test "raw SQL cannot repeat an idempotency key for the same user, but another user may reuse it" do
    ActiveRecord::Base.connection.execute(insert_sql(idempotency_key: "same"))
    rejected_by_database(idempotency_key: "same")
    other = build_user
    assert_nothing_raised { ActiveRecord::Base.connection.execute(insert_sql(user_id: other.id, idempotency_key: "same")) }
  end

  test "raw SQL can insert a valid adjustment in both directions" do
    ActiveRecord::Base.connection.execute(insert_sql(kind: "adjustment", amount: -3, idempotency_key: "adj-1"))
    ActiveRecord::Base.connection.execute(insert_sql(kind: "adjustment", amount: 3, idempotency_key: "adj-2"))
    assert_equal 0, Coins::Balance.total(@user)
  end

  test "deleting a user deletes their coin rows" do
    CoinTransaction.create!(user: @user, amount: 10, kind: "refund", idempotency_key: "x")
    assert_difference -> { CoinTransaction.count }, -1 do
      User.where(id: @user.id).delete_all
    end
  end
end
