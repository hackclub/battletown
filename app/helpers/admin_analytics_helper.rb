# How one cell of an Analytics::Report table is shown on /admin/analytics. Every status is words on a pill, never colour alone.
module AdminAnalyticsHelper
  STATUS_BADGES = { "ok" => "badge--success", "stale" => "badge--danger", "failed" => "badge--danger", "never_run" => "badge--danger",
                    "running" => "badge--muted", "off" => "badge--muted", "unscheduled" => "badge--muted" }.freeze

  def analytics_cell(column, value)
    return "-" if value.nil? || value == ""
    return value if value.is_a?(String) && value == Analytics::Report::SUPPRESSED

    case column.kind
    when :count then number_with_delimiter(value)
    when :percent then "#{number_with_precision(value, precision: 1)}%"
    when :hours then number_with_precision(value, precision: 1, delimiter: ",")
    when :bytes then number_to_human_size(value)
    when :time then tag.time(Time.iso8601(value).strftime("%-d %b %H:%M"), datetime: value, title: "UTC")
    when :status then admin_badge(Analytics::Report::Sections::STATUS_TEXT.fetch(value, value.humanize), STATUS_BADGES.fetch(value, "badge--muted"))
    else value
    end
  end

  def analytics_range_label(key) = key == "all" ? "All time" : "Last #{key} days"

  def analytics_download_path(table, range, format) = admin_analytics_path(format: format, report: table.key, range: range)
end
