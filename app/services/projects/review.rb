module Projects
  # Staff project review: mark a project OK, flag it (with a reason), clear a flag, or add a note to the current state.
  # It is a staff-only quality and safety tool. A review NEVER changes coding, hours, coins or a teen's ability to ship,
  # and the teen is not told (making flags visible to the teen is an owner decision, not built).
  #
  # Each call appends one ProjectReview row and copies it onto the project (`review_status`, `reviewed_at`) in ONE
  # transaction, under the project row lock, and writes the audit event inside the same transaction: either all three
  # happen or none. The newest row is the current state, so two staff acting at once end with the later one winning and
  # both kept in the history. Staff can never review their own project.
  module Review
    class Invalid < ArgumentError; end

    class OwnProject < Invalid
      def initialize(message = OWN_PROJECT_MESSAGE) = super
    end

    OWN_PROJECT_MESSAGE = "This is your own project, so someone else on the team has to review it.".freeze
    # Quick reasons for a flag (the stored note is "<reason>: <details>"), shown in this order.
    REASONS = [ "Inappropriate content", "Looks like someone else's work", "Links don't work", "Needs a safety check", "Other" ].freeze
    AUDIT_ACTIONS = { ok: "project_reviewed", flag: "project_flagged", clear: "project_cleared", note: "project_note_added" }.freeze

    module_function

    # A flag needs a reason: one of REASONS and/or details (details alone are fine; "Other" needs them). Returns the note text.
    def flag_note(preset:, details:)
      preset = preset.to_s.squish
      preset = "" unless REASONS.include?(preset)
      details = details.to_s.squish
      raise Invalid, "Pick a reason or write a few words about why." if preset.empty? && details.empty?
      raise Invalid, "Say a few words about why when the reason is Other." if preset == "Other" && details.empty?

      too_long!([ preset.presence, details.presence ].compact.join(": "))
    end

    def ok(project:, reviewer:, note: nil) = record(:ok, project, reviewer, too_long!(note.to_s.squish.presence))

    def flag(project:, reviewer:, preset: nil, details: nil) = record(:flag, project, reviewer, flag_note(preset: preset, details: details))

    def clear(project:, reviewer:, note: nil) = record(:clear, project, reviewer, too_long!(note.to_s.squish.presence))

    def add_note(project:, reviewer:, note:)
      text = note.to_s.squish
      raise Invalid, "Write the note first." if text.empty?

      record(:note, project, reviewer, too_long!(text))
    end

    def too_long!(text)
      return text if text.nil? || text.length <= ProjectReview::NOTE_MAX

      raise Invalid, "That is #{text.length} characters; the limit is #{ProjectReview::NOTE_MAX}."
    end

    def record(action, project, reviewer, note)
      raise Invalid, "Only signed-in staff can review a project." unless reviewer
      raise OwnProject if reviewer.id == project.user_id

      review = nil
      project.with_lock do
        status = status_for(action, project)
        review = ProjectReview.create!(project: project, reviewer: reviewer, status: status, note: note, created_at: Time.current)
        project.update_columns(review_status: status, reviewed_at: review.created_at)
        ReviewAudit.record!(actor: reviewer, action: AUDIT_ACTIONS.fetch(action), project: project, status: status)
      end
      review
    end

    # The status the new row carries; refuses a step that makes no sense for the state the project is in NOW (read under the lock).
    def status_for(action, project)
      case action
      when :ok then "ok"
      when :flag then "flagged"
      when :clear
        raise Invalid, "This project is not flagged any more, so nothing was changed." unless project.review_flagged?

        "ok"
      when :note
        raise Invalid, "Review the project (mark it OK or flag it) before adding a note." if project.review_unreviewed?

        project.review_status
      end
    end
    private_class_method :status_for
  end
end
