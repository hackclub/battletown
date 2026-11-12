module Projects
  # Answers to "is this Hackatime project yours?". Nothing is linked without an explicit accept!.
  #
  # Event hook for other features (the Slack reminder task subscribes; this code never sends a message):
  #
  #   ActiveSupport::Notifications.subscribe("project_link_suggested.battletown") do |event|
  #     suggestion = LinkSuggestion.find_by(id: event.payload[:suggestion_id])
  #   end
  #
  # It fires once, right after a NEW pending suggestion is saved (never for a repeat, accepted or declined one).
  # The payload carries only the suggestion id: look the rest up, and treat the row as possibly gone.
  module LinkSuggestions
    EVENT = "project_link_suggested.battletown".freeze

    class NotPending < StandardError; end

    module_function

    # Links the suggested Hackatime project to the suggestion's project (link_method "confirmed") and marks it
    # accepted. Returns the HackatimeLink. Raises NotPending if it was already answered, or
    # ActiveRecord::RecordInvalid if the Hackatime project got linked elsewhere in the meantime.
    def accept!(suggestion)
      LinkSuggestion.transaction do
        suggestion.lock!
        raise NotPending, "suggestion already #{suggestion.state}" unless suggestion.pending?

        project = suggestion.project
        link = project.hackatime_links.create!(user_id: project.user_id, hackatime_project: suggestion.hackatime_project, link_method: "confirmed")
        suggestion.update!(state: "accepted")
        link
      end
    end

    # Remembers the "no": the suggestion stays (state declined) so the same question is never asked again.
    def decline!(suggestion)
      suggestion.with_lock do
        raise NotPending, "suggestion already #{suggestion.state}" unless suggestion.pending?

        suggestion.update!(state: "declined")
      end
      suggestion
    end

    # Records a pending suggestion unless this (project, name) was ever suggested before. Returns it, or nil when
    # one already existed. Instruments after the row is saved.
    def suggest!(project, hackatime_project)
      # A savepoint, so losing a race on the unique index cannot poison a surrounding transaction.
      suggestion = LinkSuggestion.transaction(requires_new: true) do
        project.link_suggestions.create!(hackatime_project: hackatime_project, state: "pending")
      end
      ActiveSupport::Notifications.instrument(EVENT, suggestion_id: suggestion.id)
      suggestion
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:hackatime_project, :taken)

      nil
    end

    # After a user unlinks a Hackatime project, remember it as declined so automatic linking leaves it alone.
    def remember_decline!(project, hackatime_project)
      suggestion = project.link_suggestions.find_or_initialize_by(hackatime_project: hackatime_project)
      suggestion.update!(state: "declined")
    rescue ActiveRecord::RecordNotUnique
      project.link_suggestions.where(hackatime_project: hackatime_project).update_all(state: "declined")
    end
  end
end
