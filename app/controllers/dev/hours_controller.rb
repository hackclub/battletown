# Development-only: add coded minutes to the signed-in user for a chosen local date, so UI states (boss, streaks,
# dashboard) can be exercised without Hackatime. Outside development every request is a 404 (same as an unknown path),
# and signed-out visitors are sent to sign in. Never reachable in test or production.
module Dev
  class HoursController < ApplicationController
    before_action :require_development!
    before_action :require_login

    def show
      @today = Hours::Days.today(current_user)
      @config = Hours::Config.current
      @days = Hours::Totals.ledger_seconds_by_date(current_user, (@today - 6)..@today)
      @first_counted = Hours::Days.first_counted_date(current_user)
    end

    def create
      date = parse_date(params[:local_date])
      minutes = params[:minutes].to_s.strip
      back = params[:return_to] == "dashboard" ? dashboard_path : dev_hours_path
      return redirect_to(back, alert: "Pick a date and a whole number of minutes.") unless date && minutes.match?(/\A\d{1,4}\z/)

      result = Hours::Credit.call(user: current_user, seconds: minutes.to_i * 60, source: "manual", local_date: date,
                                  hackatime_project: hackatime_project_for(params), note: "Dev page", created_by: "dev:hours", idempotency_key: "manual:dev:#{SecureRandom.hex(8)}")
      redirect_to back, notice: result.capped? ? "That day is already at the daily cap." : "Added #{result.credited_seconds / 60} minutes."
    rescue Hours::Credit::Rejected => error
      redirect_to back, alert: "Not added: #{error.message}."
    end

    private

    # The Hackatime project name the time is credited to. From the dashboard's dev button (`for_active_project`) it is the active
    # project's first linked name, linking a made-up one ("dev-time") when it has none, so the time counts toward a ship.
    def hackatime_project_for(params)
      return params[:hackatime_project].to_s.strip.presence unless params[:for_active_project].present?

      project = current_user.active_project
      return unless project

      project.hackatime_links.order(:id).first&.hackatime_project ||
        project.hackatime_links.create!(user: current_user, hackatime_project: "dev-time", link_method: "manual").hackatime_project
    end

    def require_development!
      raise ActionController::RoutingError, "Not Found" unless Rails.env.development?
    end

    def parse_date(text)
      Date.iso8601(text.to_s)
    rescue Date::Error
      nil
    end
  end
end
