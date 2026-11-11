require "test_helper"
require "rake"

class PrivacyRequestTokenTest < ActiveSupport::TestCase
  def insert_invalid(**attrs)
    assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::NotNullViolation) do
      PrivacyRequestToken.transaction(requires_new: true) { PrivacyRequestToken.new(created_at: Time.current, **attrs).save!(validate: false) }
    end
  end

  test "a jti can only be consumed once" do
    claims = Privacy::TokenVerifier::Claims.new(jti: "once", request_id: "r", action: "delete", dry_run: true, subject: nil)
    PrivacyRequestToken.consume!(claims)
    assert_raises(PrivacyRequestToken::Replayed) { PrivacyRequestToken.consume!(claims) }
    assert_equal 1, PrivacyRequestToken.where(jti: "once").count
  end

  test "the database refuses an empty, missing or oversized jti and an unknown action" do
    insert_invalid(jti: "")
    insert_invalid(jti: "x" * 256)
    insert_invalid(jti: nil)
    insert_invalid(jti: "a", action: "purge")
    insert_invalid(jti: "b", request_id: "r" * 256)
  end

  test "purge_expired removes rows older than 7 days only" do
    PrivacyRequestToken.create!(jti: "old", created_at: 8.days.ago)
    PrivacyRequestToken.create!(jti: "new", created_at: 6.days.ago)
    assert_equal 1, PrivacyRequestToken.purge_expired
    assert_equal [ "new" ], PrivacyRequestToken.pluck(:jti)
  end

  test "the privacy:purge_tokens task purges" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("privacy:purge_tokens")
    PrivacyRequestToken.create!(jti: "old", created_at: 8.days.ago)
    PrivacyRequestToken.create!(jti: "new", created_at: 1.day.ago)

    out, = capture_io { Rake::Task["privacy:purge_tokens"].execute }

    assert_equal "privacy:purge_tokens deleted=1\n", out
    assert_equal [ "new" ], PrivacyRequestToken.pluck(:jti)
  end
end
