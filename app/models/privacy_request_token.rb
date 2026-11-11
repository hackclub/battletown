# The ids of the data-deletion/export tokens already accepted (see Privacy::TokenVerifier). The unique index on
# `jti` is what rejects a replay, so two simultaneous uses of one token cannot both succeed.
class PrivacyRequestToken < ApplicationRecord
  RETENTION = 7.days

  class Replayed < StandardError; end

  # Records the verified token's id; raises Replayed if it was used before.
  def self.consume!(claims)
    create!(jti: claims.jti, request_id: claims.request_id, action: claims.action, dry_run: claims.dry_run)
  rescue ActiveRecord::RecordNotUnique
    raise Replayed
  end

  def self.purge_expired(now: Time.current)
    where(created_at: ...(now - RETENTION)).delete_all
  end
end
