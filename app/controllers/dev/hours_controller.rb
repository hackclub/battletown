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
      @days = Hours::Totals.seconds_by_date(current_user, (@today - 6)..@today)
    end

    def create
      date = parse_date(params[:local_date])
      minutes = params[:minutes].to_s.strip
      return redirect_to(dev_hours_path, alert: "Pick a date and a whole number of minutes.") unless date && minutes.match?(/\A\d{1,4}\z/)

      result = Hours::Credit.call(user: current_user, seconds: minutes.to_i * 60, source: "manual", local_date: date,
                                  hackatime_project: params[:hackatime_project].to_s.strip.presence, note: "Dev page", created_by: "dev:hours", idempotency_key: "manual:dev:#{SecureRandom.hex(8)}")
      redirect_to dev_hours_path, notice: result.capped? ? "That day is already at the daily cap." : "Added #{result.credited_seconds / 60} minutes."
    rescue Hours::Credit::Rejected => error
      redirect_to dev_hours_path, alert: "Not added: #{error.message}."
    end

    private

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
