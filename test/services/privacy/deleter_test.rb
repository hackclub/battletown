require "test_helper"
require_relative "../../support/privacy_helper"
require_relative "../../support/hackatime_helper"

class PrivacyDeleterTest < ActiveSupport::TestCase
  include PrivacyHelper
  include HackatimeHelper

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

  test "a real deletion asks Hackatime to revoke the person's tokens; a dry run never does" do
    fake = start_fake_hackatime
    fake.on("POST", "/oauth/revoke") { |_req| [ 200, {} ] }
    user = users(:onboarded)
    connect_hackatime(user, refresh_token: SECRET_REFRESH)
    subject = subject_for(identity_id: user.hca_uid)

    Privacy::Deleter.new(subject).call(dry_run: true)
    assert_empty fake.requests_for("POST", "/oauth/revoke")

    result = Privacy::Deleter.new(subject).call(dry_run: false)
    assert_equal 1, result.deleted["hackatime_connections"]
    assert_equal [ SECRET_REFRESH, SECRET_TOKEN ].sort, fake.requests_for("POST", "/oauth/revoke").map { |r| r.form["token"] }.sort
  ensure
    stop_fake_hackatime
  end

  test "Hackatime being unreachable never blocks a deletion" do
    start_fake_hackatime.stop
    user = users(:onboarded)
    connect_hackatime(user)

    result = Privacy::Deleter.new(subject_for(identity_id: user.hca_uid)).call(dry_run: false)

    assert result.found
    assert_not User.exists?(user.id)
    assert_not HackatimeConnection.exists?(user_id: user.id)
  ensure
    stop_fake_hackatime
  end

  test "a connection whose tokens cannot be read never blocks a deletion" do
    user = users(:onboarded)
    connect_hackatime(user)
    deleter = Privacy::Deleter.new(subject_for(identity_id: user.hca_uid))

    stub_method(Hackatime::Client, :revoke, ->(*) { raise ActiveRecord::Encryption::Errors::Decryption }) do
      assert deleter.call(dry_run: false).found
    end
    assert_not User.exists?(user.id)
  end

  test "revoking stays inside the yeeter's time limit: short timeouts and no new call once the budget is spent" do
    user = users(:onboarded)
    connect_hackatime(user, refresh_token: SECRET_REFRESH)
    calls = []
    slow = lambda do |token, timeout: nil, **|
      calls << [ token, timeout ]
      travel Privacy::Deleter::REVOKE_BUDGET.seconds + 1.second
    end

    stub_method(Hackatime::Client, :revoke, slow) do
      assert Privacy::Deleter.new(subject_for(identity_id: user.hca_uid)).call(dry_run: false).found
    end

    assert_equal [ [ SECRET_TOKEN, Privacy::Deleter::REVOKE_TIMEOUT ] ], calls
    assert_not User.exists?(user.id)
  ensure
    travel_back
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
