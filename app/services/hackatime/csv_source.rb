require "csv"

module Hackatime
  # Reports Hackatime time from a CSV file an operator hands over (never committed; pass the path as an argument).
  #
  #   slack_id,date,seconds[,project]
  #   U01ABCDEF,2026-11-13,5400,my-game
  #
  # `date` is the user's local date (YYYY-MM-DD) and `seconds` the TOTAL for that day and project, as Hackatime
  # reports it. Users are matched by `users.slack_id`. The whole file is read once; a row that cannot be used (missing
  # or malformed field, negative or over-a-day seconds, project name over 120 characters) is skipped and counted. When
  # a (slack id, date, project) appears twice the last row wins. This class never logs anything: slack ids stay inside it.
  class CsvSource
    include Source

    REQUIRED_HEADERS = %w[slack_id date seconds].freeze
    SLACK_ID_FORMAT = /\A[A-Za-z0-9]{2,32}\z/
    DATE_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
    SECONDS_FORMAT = /\A\d{1,6}\z/

    attr_reader :row_count, :invalid_row_count

    def initialize(path)
      raise ArgumentError, "CSV file not found" unless path.present? && File.file?(path.to_s)

      @row_count = 0
      @invalid_row_count = 0
      @days = Hash.new { |hash, slack_id| hash[slack_id] = {} }
      read(path.to_s)
    end

    def daily_seconds(user:, from: nil, to: nil)
      return [] if user.slack_id.blank?

      @days.fetch(user.slack_id, {}).values.select { |day| (from.nil? || day.date >= from) && (to.nil? || day.date <= to) }
    end

    # How many distinct Slack ids in the file belong to no user (a count only, never the ids).
    def unknown_slack_id_count
      ids = @days.keys
      ids.size - User.where(slack_id: ids).distinct.count(:slack_id)
    end

    # The users in the file, for a batch import.
    def users = User.where(slack_id: @days.keys)

    private

    def read(path)
      table = CSV.read(path, headers: true, encoding: "bom|utf-8", skip_blanks: true)
      headers = table.headers.map { |header| header.to_s.strip }
      raise ArgumentError, "CSV needs the columns #{REQUIRED_HEADERS.join(', ')}" if (REQUIRED_HEADERS - headers).any?

      table.each do |row|
        @row_count += 1
        add(headers.zip(row.fields).to_h)
      end
    rescue CSV::MalformedCSVError, EncodingError
      raise ArgumentError, "CSV is malformed or not valid UTF-8"
    end

    def add(fields)
      slack_id = fields["slack_id"].to_s.strip
      date = fields["date"].to_s.strip
      seconds = fields["seconds"].to_s.strip
      project = fields["project"].to_s.strip.presence
      valid = slack_id.match?(SLACK_ID_FORMAT) && date.match?(DATE_FORMAT) && seconds.match?(SECONDS_FORMAT) &&
              seconds.to_i <= HourEntry::MAX_SECONDS && (project.nil? || project.length <= 120)
      parsed = valid && parse_date(date)
      return @invalid_row_count += 1 unless parsed

      @days[slack_id][[ parsed, project ]] = DaySeconds.new(date: parsed, seconds: seconds.to_i, project: project)
    end

    def parse_date(text)
      Date.strptime(text, "%Y-%m-%d")
    rescue Date::Error
      nil
    end
  end
end
