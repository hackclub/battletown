require "test_helper"
require_relative "../support/shop_helper"

class OrderTest < ActiveSupport::TestCase
  include ShopTestHelper

  setup { @user = build_user }

  def attrs(overrides = {})
    { user: @user, prize_key: "tshirt", prize_name: "Battletown T-shirt", coins: 50, kind: "purchase", idempotency_key: "k-#{SecureRandom.hex(4)}" }.merge(overrides)
  end

  # Inserts past the model, as raw SQL, so only the database can say no.
  def raw_insert(kind: "purchase", status: "requested", coins: 50, key: "raw-#{SecureRandom.hex(4)}", fulfilled_at: "NULL", cancelled_at: "NULL",
                 prize_key: "tshirt", user_id: @user.id)
    # A savepoint, so a rejected insert does not poison the test's transaction.
    Order.transaction(requires_new: true) { Order.connection.execute(<<~SQL) }
      INSERT INTO orders (user_id, prize_key, prize_name, coins, kind, status, idempotency_key, fulfilled_at, cancelled_at, created_at, updated_at)
      VALUES (#{user_id}, '#{prize_key}', 'Name', #{coins}, '#{kind}', '#{status}', '#{key}', #{fulfilled_at}, #{cancelled_at}, now(), now())
    SQL
  end

  test "a valid order saves with the requested status by default" do
    order = Order.create!(attrs)
    assert_equal "requested", order.status
    assert_predicate order, :requested?
  end

  test "the model validates the allowlists" do
    assert_not Order.new(attrs(prize_key: "nope")).valid?
    assert_not Order.new(attrs(kind: "gift")).valid?
    assert_not Order.new(attrs(status: "lost")).valid?
    assert_not Order.new(attrs(coins: -1)).valid?
    assert_not Order.new(attrs(coins: 0)).valid?, "a purchase costs something"
    assert_not Order.new(attrs(kind: "signup_sticker", prize_key: "signup_sticker", coins: 5)).valid?
    assert_not Order.new(attrs(idempotency_key: "")).valid?
    assert Order.new(attrs(kind: "signup_sticker", prize_key: "signup_sticker", coins: 0)).valid?
  end

  test "the database refuses what the model refuses, even by raw SQL" do
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(coins: -1) }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(kind: "gift") }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(status: "lost") }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(coins: 0) }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(kind: "signup_sticker", coins: 5) }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(key: "") }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(key: "x" * 101) }
    assert_equal 0, Order.count
  end

  test "the status and its timestamp must agree" do
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(status: "fulfilled") }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(status: "cancelled") }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(status: "requested", fulfilled_at: "now()") }
    assert_raises(ActiveRecord::StatementInvalid) { raw_insert(status: "requested", cancelled_at: "now()") }
    raw_insert(status: "fulfilled", fulfilled_at: "now()")
    raw_insert(status: "cancelled", cancelled_at: "now()")
    assert_equal 2, Order.count
  end

  test "an idempotency key is unique per user, not across users" do
    raw_insert(key: "same")
    assert_raises(ActiveRecord::RecordNotUnique) { raw_insert(key: "same") }
    raw_insert(key: "same", user_id: build_user.id)
    assert_equal 2, Order.count
  end

  test "a user has at most one signup sticker order, however it is inserted" do
    raw_insert(kind: "signup_sticker", coins: 0, key: "one", prize_key: "signup_sticker")
    assert_raises(ActiveRecord::RecordNotUnique) { raw_insert(kind: "signup_sticker", coins: 0, key: "two", prize_key: "signup_sticker") }
    assert_raises(ActiveRecord::RecordNotUnique) { Order.create!(attrs(kind: "signup_sticker", prize_key: "signup_sticker", coins: 0)) }
    raw_insert(kind: "purchase", key: "many-1")
    raw_insert(kind: "purchase", key: "many-2")
    assert_equal 3, Order.where(user_id: @user.id).count
  end

  test "the user foreign key cascades: deleting the user deletes their orders" do
    other = build_user
    Order.create!(attrs)
    Order.create!(attrs(user: other))
    @user.destroy!
    assert_equal [ other.id ], Order.pluck(:user_id)
    assert_empty Order.where(user_id: @user.id)
    other.delete
    assert_equal 0, Order.count
  end

  test "a raw user delete cascades too, and the privacy deleter counts the orders" do
    Order.create!(attrs)
    subject = Privacy::TokenVerifier::Subject.new(emails: [], slack_id: nil, identity_id: @user.hca_uid)
    result = Privacy::Deleter.new(subject).call(dry_run: false)
    assert_equal 1, result.deleted["orders"]
    assert_equal 0, Order.count
  end

  test "an order whose item has left the catalogue still shows its name" do
    order = Order.create!(attrs)
    order.update_columns(prize_key: "retired_item")
    assert_nil order.prize
    assert_equal "Battletown T-shirt", order.display_name
  end

  test "queue order puts requested first" do
    done = Order.create!(attrs(status: "fulfilled", fulfilled_at: Time.current))
    waiting = Order.create!(attrs(created_at: 1.day.ago))
    assert_equal [ waiting.id, done.id ], Order.queue_order.pluck(:id)
  end
end
