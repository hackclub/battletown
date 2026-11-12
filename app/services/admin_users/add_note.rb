module AdminUsers
  # Appends a private staff note to a person and records the audit event (the note text itself stays out of the trail).
  class AddNote
    class Invalid < StandardError; end

    def self.call(staff:, user:, body:)
      note = UserNote.new(user: user, author: staff, body: body, created_at: Time.current)
      raise Invalid, "The note #{note.errors.full_messages_for(:body).first.to_s.delete_prefix('Body ')}" unless note.valid?

      UserNote.transaction do
        note.save!
        AdminAudit.record!(actor: staff, action: "user_note_added", subject: user, metadata: { note_id: note.id })
      end
      note
    end
  end
end
