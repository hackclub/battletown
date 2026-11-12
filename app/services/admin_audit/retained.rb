module AdminAudit
  # Which audit rows belong to a person who asks to be deleted (Privacy::Deleter). The trail has no foreign key to its subject
  # (a type name and an id), so the database cannot cascade it; this says which rows to remove and which to keep and report.
  module Retained
    # Subject types whose rows belong to a person through a user_id column.
    OWNED = { "Order" => Order, "Project" => Project, "Ship" => Ship, "MerchClaim" => MerchClaim, "NpsResponse" => NpsResponse }.freeze

    module_function

    # Rows whose subject IS the person: deleted with them (they can carry a staff-typed reason).
    def about_person(user_ids) = AdminAuditEvent.unscoped.where(subject_type: "User", subject_id: user_ids)

    # Rows whose subject is one of the person's records. Kept: ids, amounts and codes only.
    def about_records_of(user_ids)
      scopes = OWNED.map { |type, model| AdminAuditEvent.where(subject_type: type, subject_id: model.where(user_id: user_ids).select(:id)) }
      scopes.reduce(:or)
    end
  end
end
