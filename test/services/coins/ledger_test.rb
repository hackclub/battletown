require "test_helper"
require_relative "../../support/coins_helper"

class Coins::LedgerTest < ActiveSupport::TestCase
  include CoinsHelper

  setup { @user = build_user }

  def credit(amount, key, kind: "ship_approval", **extra)
    Coins::Ledger.credit(user: @user, amount: amount, kind: kind, idempotency_key: key, **extra)
  end

  def debit(amount, key, kind: "purchase", **extra)
    Coins::Ledger.debit(user: @user, amount: amount, kind: kind, idempotency_key: key, **extra)
  end

  test "a new user has a zero balance" do
    assert_equal 0, Coins::Balance.total(@user)
  end

  test "credits add and debits subtract, a debit is stored negative" do
    credit(100, "c1")
    entry = debit(30, "d1")
    assert_equal(-30, entry.amount)
    assert_equal 70, Coins::Balance.total(@user)
  end

  test "a debit that would make the balance negative raises and writes nothing" do
    credit(10, "c1")
    assert_raises(Coins::InsufficientBalance) { debit(11, "d1") }
    assert_equal 10, Coins::Balance.total(@user)
    assert_equal 1, CoinTransaction.where(user_id: @user.id).count
  end

  test "spending the exact balance is allowed" do
    credit(10, "c1")
    debit(10, "d1")
    assert_equal 0, Coins::Balance.total(@user)
  end

  test "a debit with no coins at all raises" do
    assert_raises(Coins::InsufficientBalance) { debit(1, "d1") }
  end

  test "the same idempotency key returns the existing row and does not repeat the effect" do
    first = credit(50, "same")
    second = credit(50, "same")
    assert_equal first.id, second.id
    assert_equal 50, Coins::Balance.total(@user)

    spent = debit(20, "spend")
    assert_equal spent.id, debit(20, "spend").id
    assert_equal 30, Coins::Balance.total(@user)
  end

  test "a repeated debit key returns the row even when the balance would no longer cover it" do
    credit(20, "c1")
    first = debit(20, "d1")
    assert_equal first.id, debit(20, "d1").id
    assert_equal 0, Coins::Balance.total(@user)
  end

  test "reusing a key for a different amount or kind raises" do
    credit(50, "k")
    assert_raises(Coins::IdempotencyConflict) { credit(51, "k") }
    assert_raises(Coins::IdempotencyConflict) { credit(50, "k", kind: "refund") }
    assert_raises(Coins::IdempotencyConflict) { debit(50, "k") }
    assert_equal 50, Coins::Balance.total(@user)
  end

  test "another user may reuse the key" do
    credit(5, "shared")
    other = build_user
    Coins::Ledger.credit(user: other, amount: 7, kind: "refund", idempotency_key: "shared")
    assert_equal 5, Coins::Balance.total(@user)
    assert_equal 7, Coins::Balance.total(other)
  end

  test "amounts must be positive integers" do
    [ 0, -5, 1.5, "5", nil ].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { credit(bad, "bad") }
      assert_raises(ArgumentError, bad.inspect) { debit(bad, "bad") }
    end
    assert_equal 0, CoinTransaction.where(user_id: @user.id).count
  end

  test "kinds must match the direction" do
    assert_raises(ArgumentError) { credit(5, "x", kind: "purchase") }
    assert_raises(ArgumentError) { debit(5, "x", kind: "ship_approval") }
    assert_raises(ArgumentError) { credit(5, "x", kind: "bogus") }
    credit(5, "adj-up", kind: "adjustment")
    debit(5, "adj-down", kind: "adjustment")
    assert_equal 0, Coins::Balance.total(@user)
  end

  test "an adjustment debit cannot overdraw either" do
    assert_raises(Coins::InsufficientBalance) { debit(1, "adj", kind: "adjustment") }
  end

  test "references are stored from a record or a pair" do
    entry = credit(5, "r1", reference: @user)
    assert_equal [ "User", @user.id ], [ entry.reference_type, entry.reference_id ]
    pair = credit(5, "r2", reference: [ "Ship", 42 ])
    assert_equal [ "Ship", 42 ], [ pair.reference_type, pair.reference_id ]
    assert_nil credit(5, "r3").reference_type
  end

  test "note and created_by are stored and validated" do
    entry = credit(5, "n1", note: "hello", created_by: "rake:adjust")
    assert_equal [ "hello", "rake:adjust" ], [ entry.note, entry.created_by ]
    assert_raises(ActiveRecord::RecordInvalid) { credit(5, "n2", created_by: "Some Person") }
  end

  test "keys longer than 120 characters are refused" do
    assert_raises(ActiveRecord::RecordInvalid) { credit(5, "k" * 121) }
  end

  test "the balance is the sum of the user's own rows only" do
    credit(40, "mine")
    other = build_user
    Coins::Ledger.credit(user: other, amount: 99, kind: "refund", idempotency_key: "theirs")
    assert_equal 40, Coins::Balance.total(@user)
  end
end
