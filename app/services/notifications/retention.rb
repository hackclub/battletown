module Notifications
  # Finished rows (sent, failed, cancelled) carry no content but are still personal data, so they do not live forever.
  module Retention
    module_function

    def prune(now: Time.current, config: Config.current)
      Notification.where.not(status: "pending").where(updated_at: ...(now - config.retention_days.days)).delete_all
    end
  end
end
