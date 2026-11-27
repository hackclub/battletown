# Aggregate numbers for the returning-user bonus panel on /admin/metrics (feature flag `returning`): per week, how many
# welcome-back windows started and how many returning nudges were sent. Counts only, never a name, email or id. Weeks run
# Friday to Thursday like the weekly boss; windows are counted on their (local) start date, nudges on the UTC date they
# were sent (rows older than notifications.retention_days are pruned, so old weeks undercount nudges).
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
    windows = WelcomeBackWindow.where(starts_on: range).group(:starts_on).count
    nudges = Notification.where(kind: "returning_nudge", status: "sent", sent_at: range.first.beginning_of_day.utc..range.last.end_of_day.utc)
                         .group("DATE(sent_at)").count.transform_keys(&:to_date)
    weeks = (0...WEEKS).map do |index|
      starts_on = first_start + (7 * index)
      days = starts_on..(starts_on + 6)
      Week.new(starts_on: starts_on, ends_on: starts_on + 6, windows_started: sum(windows, days), nudges_sent: sum(nudges, days),
               partial: starts_on + 6 > @today)
    end
    Panel.new(weeks: weeks, windows_total: WelcomeBackWindow.count, nudges_total: Notification.where(kind: "returning_nudge", status: "sent").count)
  end

  private

  def sum(counts, days) = counts.sum { |date, count| days.cover?(date) ? count : 0 }
end
