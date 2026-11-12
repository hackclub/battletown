require "test_helper"

class AdminStatsTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 11, 11)

  def stats = AdminStats.call(today: TODAY)

  def counts(rows) = rows.to_h { |row| [ row.label, row.count ] }

  def query_count
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { stats }
    queries.size
  end

  test "counts users and onboarded users" do
    assert_equal 2, stats.total_users
    assert_equal 1, stats.onboarded
  end

  test "signups per day cover the last 14 UTC days, oldest first, zero-filled" do
    User.update_all(created_at: Time.utc(2026, 1, 1))
    users(:new_user).update_columns(created_at: Time.utc(2026, 11, 11, 23, 59))
    users(:onboarded).update_columns(created_at: Time.utc(2026, 10, 29, 0, 0))

    rows = stats.signups_per_day
    assert_equal 14, rows.size
    assert_equal "2026-10-29", rows.first.label
    assert_equal "2026-11-11", rows.last.label
    assert_equal 1, rows.first.count
    assert_equal 1, rows.last.count
    assert_equal 2, rows.sum(&:count)
  end

  test "signups just outside the window are not counted" do
    User.update_all(created_at: Time.utc(2026, 10, 28, 23, 59))
    assert_equal 0, stats.signups_per_day.sum(&:count)
  end

  test "funnel is cumulative reached-at-least-step counts" do
    # new_user is at step 0, onboarded at step 4.
    assert_equal({ "Step 0" => 2, "Step 1" => 1, "Step 2" => 1, "Step 3" => 1, "Step 4" => 1 }, counts(stats.onboarding_funnel))
    users(:new_user).update_columns(onboarding_step: 2)
    assert_equal({ "Step 0" => 2, "Step 1" => 2, "Step 2" => 2, "Step 3" => 1, "Step 4" => 1 }, counts(stats.onboarding_funnel))
  end

  test "verification lists every status, zero included" do
    assert_equal({ "Needs submission" => 2, "Pending" => 0, "Verified" => 0, "Ineligible" => 0 }, counts(stats.verification))
  end

  test "referral sources use display names, fold unknown keys into other, and count no answer" do
    users(:new_user).update_columns(referral_source: "haven")
    users(:onboarded).update_columns(referral_source: "mystery_key")
    assert_equal({ "Haven" => 1, "Something else" => 1 }, counts(stats.referral_sources))

    users(:onboarded).update_columns(referral_source: nil)
    assert_equal({ "Haven" => 1, "No answer" => 1 }, counts(stats.referral_sources))
  end

  test "prize picks and project kinds, with the unset bucket" do
    prizes = counts(stats.prizes)
    assert_equal 1, prizes[Prize.find("tshirt").name]
    assert_equal 1, prizes["No pick yet"]
    assert_equal Prize.paid.size + 1, prizes.size

    kinds = counts(stats.project_kinds)
    assert_equal 1, kinds["Game"]
    assert_equal 1, kinds["Not chosen"]
    assert_equal 0, kinds["Hardware"]
  end

  test "the number of queries does not grow with the number of users" do
    before = query_count
    5.times { |i| User.create!(hca_uid: "extra-#{i}") }
    assert_equal before, query_count
  end

  test "result holds only labels and counts" do
    stats.to_h.each_value do |value|
      assert(value.is_a?(Integer) || value.all?(AdminStats::Row))
    end
  end
end
