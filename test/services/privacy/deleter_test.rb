require "test_helper"
require_relative "../../support/privacy_helper"

class PrivacyDeleterTest < ActiveSupport::TestCase
  include PrivacyHelper

  def subject_for(**attrs) = Privacy::TokenVerifier::Subject.new(**{ emails: [], slack_id: nil, identity_id: nil }.merge(attrs))

  test "a dry run is rolled back and the real run reports the same counts" do
    user = users(:onboarded)
    2.times { |i| Notification.create!(user: user, kind: "daily_reminder", status: "sent", scheduled_for: Time.current, due_at: Time.current, idempotency_key: "d-#{i}") }
    subject = subject_for(identity_id: user.hca_uid)

    dry = Privacy::Deleter.new(subject).call(dry_run: true)
    assert User.exists?(user.id)
    assert_equal 2, Notification.where(user_id: user.id).count

    real = Privacy::Deleter.new(subject).call(dry_run: false)
    assert_equal dry, real
    assert_equal({ "notifications" => 2, "users" => 1 }, real.deleted)
    assert_not User.exists?(user.id)
  end

  test "an unknown subject changes nothing" do
    result = Privacy::Deleter.new(subject_for(emails: [ "nobody@example.com" ])).call(dry_run: false)
    assert_equal [ false, {}, [] ], [ result.found, result.deleted, result.retained ]
  end

  test "retained records are reported with type, count and reason, and zero counts are left out" do
    user = users(:onboarded)
    rules = [ { type: "orders", reason: "Accounting", count: ->(ids) { ids.size * 2 } },
              { type: "nothing", reason: "unused", count: ->(_ids) { 0 } } ]

    with_retention_rules(rules) do
      result = Privacy::Deleter.new(subject_for(identity_id: user.hca_uid)).call(dry_run: true)
      assert_equal [ { type: "orders", count: 2, reason: "Accounting" } ], result.retained
    end
  end

  test "it refuses to report when the counters do not account for the users" do
    user = users(:onboarded)
    deleter = Privacy::Deleter.new(subject_for(identity_id: user.hca_uid))

    stub_method(deleter, :delete_counters, -> { Hash.new(0) }) do
      assert_raises(RuntimeError) { deleter.call(dry_run: false) }
    end
    assert User.exists?(user.id)
  end

  private

  def with_retention_rules(rules)
    original = Privacy::Deleter::RETENTION_RULES
    Privacy::Deleter.send(:remove_const, :RETENTION_RULES)
    Privacy::Deleter.const_set(:RETENTION_RULES, rules)
    yield
  ensure
    Privacy::Deleter.send(:remove_const, :RETENTION_RULES)
    Privacy::Deleter.const_set(:RETENTION_RULES, original)
  end
end
