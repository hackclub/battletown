module Projects
  # Hours coded on a project, for the staff views only: the net ledger seconds of the owner's entries whose Hackatime
  # project is linked to the project, on counted dates only (the sign-up cutoff in docs/CONTRACT.md, "Hours ledger"),
  # floored at zero. This is the live total, not what a ship has already covered. Read-only.
  module CodedTime
    WEEK_START = :friday # weeks run Friday to Thursday, like the weekly boss

    module_function

    # SQL for a derived table `project_id, coded_seconds` over every project that has a link and counted time, so a queue can
    # LEFT JOIN it once (no query per row) and sort by it.
    def totals_sql(config: Hours::Config.current)
      Project.sanitize_sql_array([ <<~SQL.squish, config.days_before_signup_counted ])
        SELECT links.project_id AS project_id, GREATEST(SUM(entries.seconds), 0) AS coded_seconds
        FROM hackatime_links links
        JOIN users owners ON owners.id = links.user_id
        JOIN hour_entries entries ON entries.user_id = links.user_id AND entries.hackatime_project = links.hackatime_project
        WHERE entries.local_date >= owners.signed_up_on - CAST(? AS integer)
        GROUP BY links.project_id
      SQL
    end

    # { Date => seconds } for one project (dates with time only).
    def seconds_by_date(project, config: Hours::Config.current)
      names = project.hackatime_links.select(:hackatime_project)
      first = Hours::Days.first_counted_date(project.user, config: config)
      HourEntry.where(user_id: project.user_id, hackatime_project: names, local_date: first..)
               .group(:local_date).sum(:seconds).select { |_, seconds| seconds.positive? }.sort.to_h
    end

    # [[week_start_date, seconds], ...] newest week first, from seconds_by_date.
    def by_week(seconds_by_date)
      seconds_by_date.group_by { |date, _| date.beginning_of_week(WEEK_START) }
                     .map { |week, rows| [ week, rows.sum { |_, seconds| seconds } ] }.sort_by { |week, _| -week.jd }
    end
  end
end
