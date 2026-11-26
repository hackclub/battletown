# Aggregate numbers for the returning-user bonus panel on /admin/metrics (feature flag `returning`): per week, how many
# welcome-back windows started and how many returning nudges were sent. Counts only, never a name, email or id. Weeks run
# Friday to Thursday like the weekly boss; windows are counted on their (local) start date, nudges on the UTC date they
# were sent (rows older than notifications.retention_days are pruned, so old weeks undercount nudges). Staff, simulated players
# and the testers in ANALYTICS_EXCLUDE_HCA_UIDS are not counted (User.analytics_included).
class ReturningMetrics
  WEEKS = 8
  WEEK_START_WDAY = 5

  Week = Data.define(:starts_on, :ends_on, :windows_started, :nudges_sent, :partial)
  Panel = Data.define(:weeks, :windows_total, :nudges_total)

  def self.call(today: Time.current.utc.to_date) = new(today).call

  def initialize(today)
    @today = today
  end

  def call
    last_start = @today - ((@today.wday - WEEK_START_WDAY) % 7)
    first_start = last_start - (7 * (WEEKS - 1))
    range = first_start..(last_start + 6)
    windows = measured_windows.where(starts_on: range).group(:starts_on).count
    nudges = nudges_sent.where(sent_at: range.first.beginning_of_day.utc..range.last.end_of_day.utc)
                        .group("DATE(sent_at)").count.transform_keys(&:to_date)
    weeks = (0...WEEKS).map do |index|
      starts_on = first_start + (7 * index)
      days = starts_on..(starts_on + 6)
      Week.new(starts_on: starts_on, ends_on: starts_on + 6, windows_started: sum(windows, days), nudges_sent: sum(nudges, days),
               partial: starts_on + 6 > @today)
    end
    Panel.new(weeks: weeks, windows_total: measured_windows.count, nudges_total: nudges_sent.count)
  end

  private

  def measured_windows = WelcomeBackWindow.where(user_id: User.analytics_included.select(:id))

  def nudges_sent = Notification.where(user_id: User.analytics_included.select(:id), kind: "returning_nudge", status: "sent")

  def sum(counts, days) = counts.sum { |date, count| days.cover?(date) ? count : 0 }
end
