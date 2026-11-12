# The one staff audit trail (table admin_audit_events, model AdminAuditEvent, page /admin/audit). Every staff action that
# changes something, or opens something sensitive, writes one row here:
#
#   AdminAudit.record!(actor: current_user, action: "hours_adjusted", subject: user,
#                      metadata: { local_date: "2026-11-10", seconds: -600, reason: "Counted twice" })
#
# - `actor` is the signed-in staff member (a saved User). The row keeps only their id, and it is nulled if they are deleted.
# - `action` must be in ACTIONS (below); an unknown one raises ActiveRecord::RecordInvalid, so a typo fails loudly.
# - `subject` is the record acted on (only its class name and id are stored) or a [type, id] pair.
# - `metadata` is a flat Hash: snake_case keys, values that are integers, booleans, nil, dates or short strings (200 characters
#   at most). Use it for ids, amounts, reason codes and the short reason a staff member typed. NEVER put names, emails, Slack
#   or Hack Club Auth ids, free text a teen wrote, or anything a screen showed; AdminAudit::Metadata refuses keys and values
#   that look personal. The detail of a change lives in the ledger or the changed row, not here.
# - Call it INSIDE the transaction that makes the change, so the change and its audit row commit or roll back together.
# - Rows are immutable once written.
#
# To add an action, put its name in your area's constant below (one line each, so branches do not collide). The page prints
# the action name with spaces, so no other change is needed.
module AdminAudit
  USER_ACTIONS = %w[
    user_viewed
    hours_adjusted
    coins_adjusted
    user_note_added
  ].freeze
  NPS_ACTIONS = %w[
    nps_comment_author_viewed
  ].freeze
  # Shop-item management adds its actions here.
  SHOP_ACTIONS = %w[
  ].freeze
  # Project and ship review adds its actions here.
  REVIEW_ACTIONS = %w[
    project_reviewed
    project_flagged
    project_cleared
    project_note_added
  ].freeze

  ACTIONS = (USER_ACTIONS + NPS_ACTIONS + SHOP_ACTIONS + REVIEW_ACTIONS).freeze

  module_function

  def record!(actor:, action:, subject:, metadata: {})
    raise ArgumentError, "actor must be a saved User" unless actor.is_a?(User) && actor.persisted?

    type, id = subject_parts(subject)
    AdminAuditEvent.create!(actor: actor, action: action.to_s, subject_type: type, subject_id: id,
                            metadata: Metadata.normalise(metadata), created_at: Time.current)
  end

  # Like record!, but writes nothing when the same actor already recorded the same action on the same subject within
  # `within` (a page view repeated by refreshing). Returns the new row, or nil when one was already recent.
  def record_once!(actor:, action:, subject:, within:, metadata: {})
    type, id = subject_parts(subject)
    recent = AdminAuditEvent.where(actor_id: actor.id, action: action.to_s, subject_type: type, subject_id: id, created_at: within.ago..)
    return nil if recent.exists?

    record!(actor: actor, action: action, subject: [ type, id ], metadata: metadata)
  end

  def subject_parts(subject)
    case subject
    when Array then [ subject.first.to_s, Integer(subject.last) ]
    else
      raise ArgumentError, "subject must be a saved record or a [type, id] pair" unless subject.respond_to?(:id) && subject.id

      [ subject.class.name, subject.id ]
    end
  end
end
