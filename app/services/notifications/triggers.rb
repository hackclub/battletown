module Notifications
  # Turns game events into outbox rows. The projects and ships code only announces what happened
  # (`ActiveSupport::Notifications.instrument`, payload = a row id); these handlers are subscribed in
  # config/initializers/notification_triggers.rb.
  #
  #   project_link_suggested.battletown (suggestion_id)  -> link_question, one per suggestion
  #   ship_approved.battletown / ship_rejected.battletown (ship_id) -> ship_approved / ship_rejected, one decision per ship
  #                                                      (and, with the `email` flag on, one email row, Email::Triggers)
  #   ship_submitted.battletown (ship_id)                -> no message; pending ship reminders for that project are cancelled
  #
  # Handlers only create or cancel outbox rows. They run inside the request that fired the event, so each one runs in
  # a savepoint and swallows any error, logging the class name only (never a message, id or recipient): a problem
  # here can never break a teen's request or a staff member's approval. Duplicate events make no second row (the
  # idempotency key), and a person without a Slack id or with the kind switched off gets nothing.
  module Triggers
    EVENTS = {
      "project_link_suggested.battletown" => :link_suggested,
      "ship_submitted.battletown" => :ship_submitted,
      "ship_approved.battletown" => :ship_approved,
      "ship_rejected.battletown" => :ship_rejected
    }.freeze

    module_function

    # Called once at boot. The block looks the handler up when an event fires, so code reloading in development
    # always runs the current version and the subscription is never doubled.
    def subscribe!
      EVENTS.each do |event, handler|
        ActiveSupport::Notifications.subscribe(event) do |*, payload|
          Notifications::Triggers.public_send(handler, payload)
        end
      end
    end

    def link_suggested(payload)
      guard("project_link_suggested") do
        suggestion = LinkSuggestion.pending.includes(project: :user).find_by(id: payload[:suggestion_id])
        next unless suggestion

        Outbox.enqueue(user: suggestion.project.user, kind: "link_question", subject_id: suggestion.id,
                       key: "link_question:#{suggestion.id}")
      end
    end

    def ship_approved(payload) = decided(payload, "ship_approved", "approved")

    def ship_rejected(payload) = decided(payload, "ship_rejected", "rejected")

    def ship_submitted(payload)
      guard("ship_submitted") do
        ship = Ship.find_by(id: payload[:ship_id])
        ShipReminders.cancel_pending_for(ship.project_id) if ship
      end
    end

    def decided(payload, kind, status)
      guard(kind) do
        ship = Ship.includes(:user).find_by(id: payload[:ship_id], status: status)
        next unless ship

        # One decision message per ship, whichever way it went.
        Outbox.enqueue(user: ship.user, kind: kind, subject_id: ship.id, key: "ship_decision:#{ship.id}")
        # And, behind the `email` flag, the same decision by email (its own row and key; a person can have either).
        Email::Triggers.ship_decision(ship, kind)
      end
    end
    private_class_method :decided

    def guard(event)
      ActiveRecord::Base.transaction(requires_new: true) { yield }
      nil
    rescue StandardError => e
      Rails.logger.warn("notifications.trigger error=#{e.class.name} event=#{event}")
      nil
    end
    private_class_method :guard
  end
end
