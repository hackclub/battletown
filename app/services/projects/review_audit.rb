module Projects
  # The seam between project review and the staff audit log. The event is written when AdminAudit (the admin audit log,
  # built on staff_access_logs) exists; until then it is a no-op and the review row itself (reviewer, status, note, time)
  # is the record. It carries the action name, the project row and the new status only: never the note text, never the
  # teen's name or any other personal data.
  module ReviewAudit
    module_function

    def record!(actor:, action:, project:, status:)
      return unless defined?(::AdminAudit)

      ::AdminAudit.record!(actor: actor, action: action, subject: project, metadata: { "status" => status })
    end
  end
end
