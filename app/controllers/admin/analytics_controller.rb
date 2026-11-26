module Admin
  # Staff analytics (Analytics::Report): server-rendered tables, no JavaScript, and a CSV or JSON download of each one. Aggregates only: no names,
  # emails, ids or anything about one person, and staff and simulated players are left out of every number. Read-only, so nothing to audit; the
  # refresh button only drops the cached numbers. Same 404 as every admin page for anyone who is not staff (BaseController).
  class AnalyticsController < BaseController
    def show
      @range = ::Analytics::Report.range(params[:range])
      respond_to do |format|
        format.html do
          # One report per page view: the slow ones (all time, a big events table) are only built when asked for.
          @report = ::Analytics::Report.key?(params[:report]) ? params[:report].to_s : ::Analytics::Report::KEYS.first
          @table = ::Analytics::Report.fetch(@report, range: @range)
        end
        format.csv { download(:csv) }
        format.json { download(:json) }
      end
    end

    def refresh
      ::Analytics::Report.expire!
      report = params[:report] if ::Analytics::Report.key?(params[:report])
      redirect_to admin_analytics_path(range: ::Analytics::Report.range(params[:range]), report: report), notice: "Numbers refreshed."
    end

    private

    # One report per download; a missing or unknown name is the same 404 as a missing page.
    def download(format)
      not_found unless ::Analytics::Report.key?(params[:report])
      table = ::Analytics::Report.fetch(params[:report], range: @range)
      name = "battletown-analytics-#{table.key}-#{@range}-#{Time.current.utc.to_date.iso8601}"
      if format == :csv
        send_data ::Analytics::Report.csv(table), type: "text/csv; charset=utf-8", filename: "#{name}.csv", disposition: "attachment"
      else
        response.headers["Content-Disposition"] = %(attachment; filename="#{name}.json")
        render json: ::Analytics::Report.json(table, range: @range)
      end
    end
  end
end
