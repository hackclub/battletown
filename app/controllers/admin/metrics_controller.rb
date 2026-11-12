module Admin
  # Read-only engagement metrics (AdminMetrics): aggregate counts and sums, no names, emails or ids.
  class MetricsController < BaseController
    def show
      @metrics = AdminMetrics.call
      @returning = ReturningMetrics.call if Features.enabled?(:returning)
    end
  end
end
