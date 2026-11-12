require_relative "notifications_helper"
require_relative "ships_test_support"

# Shared helpers for the email notification tests (Notifications::Email). Nothing here sends mail: the mailer runs on
# Action Mailer's :test delivery method (ActionMailer::Base.deliveries), and the dispatcher tests use FakeAdapter.
# Addresses are example.test / example.com only.
module EmailHelper
  include NotificationsHelper
  include ShipsTestSupport

  ADDRESS = "teen@example.test".freeze

  # Records what the dispatcher asked it to send and answers from a queue of Results (the last repeats; default ok).
  # `delivers: false` behaves like a transport that does not really deliver (the log or null adapter).
  class FakeAdapter < Notifications::Email::Adapter
    attr_reader :calls

    def initialize(*results, delivers: true)
      @results = results
      @calls = []
      @delivers = delivers
    end

    def delivers? = @delivers

    def deliver(user:, kind:, values:)
      @calls << { user_id: user.id, kind: kind, values: values }
      @results.size > 1 ? @results.shift : (@results.first || Notifications::Email::Result.success)
    end
  end

  # An onboarded user with a (fake) address. Signed up long before any test date.
  def create_email_user(suffix = SecureRandom.hex(4), **attrs)
    create_user(suffix, **{ email: "teen-#{suffix}@example.test" }.merge(attrs))
  end

  # A ship decided through the real services (so the real events fire, and the Slack and email triggers run).
  def decided_ship(user, decision, name: "Space Farm")
    project = make_project(user, name: name)
    3.times { |i| code(user, Date.new(2026, 11, 7 + i), HOUR) }
    ship = submit_ship(project)
    reviewer = users(:onboarded)
    if decision == :approved
      Ships::Approve.call(ship: ship, reviewer: reviewer, approved_seconds: ship.coded_seconds, now: Time.utc(2026, 11, 10, 12))
    else
      Ships::Reject.call(ship: ship, reviewer: reviewer, reason: "The demo link does not open")
    end
    ship.reload
  end

  def email_row(user, kind: "ship_approved", subject_id: 20_000, due_at: Time.current, status: "pending", key: nil)
    Notification.create!(user: user, kind: kind, channel: "email", status: status, subject_id: subject_id, scheduled_for: due_at, due_at: due_at,
                         idempotency_key: key || "email:test:#{SecureRandom.hex(6)}")
  end

  # The mail Action Mailer collected (test delivery method), emptied first.
  def clear_deliveries = ActionMailer::Base.deliveries.clear

  def deliveries = ActionMailer::Base.deliveries
end
