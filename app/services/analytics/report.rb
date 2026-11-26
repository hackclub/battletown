require "csv"

module Analytics
  # The staff analytics page (/admin/analytics) and its CSV and JSON downloads: aggregate tables only, built from the live tables and the
  # collection layer (plans/analytics.md, sections 3 and 7). Every report is one `Table` (columns plus rows of plain numbers and words), so the
  # page, the CSV and the JSON are the same data and none can show more than another.
  #
  # Privacy: no row carries a person (no id, no name, no email, no uid): only counts, sums, a referral slug, an enum or a job name. Staff,
  # simulated players and listed testers are left out of every number (Analytics::Exclusion.included_sql). A cell in a breakdown (by referral,
  # referrer, device, event name) that counts one to four people or events is shown as "<5", in the page and in both downloads; totals, funnel
  # steps and the time series are never hidden. Nothing here deletes or prunes anything.
  #
  #   Analytics::Report.fetch(:daily, range: "30")   # -> a Table, cached for 5 minutes
  #   Analytics::Report.csv(table) / Analytics::Report.json(table, range: "30")
  module Report
    RANGES = %w[7 14 30 all].freeze
    DEFAULT_RANGE = "7".freeze
    KEYS = %w[visits funnel stuck cohorts daily referrals events jobs tables].freeze
    # The report names on the page's menu (each table carries its own longer title).
    LABELS = { "visits" => "Visitor funnel", "funnel" => "Participant funnel", "stuck" => "Stuck at", "cohorts" => "Cohorts", "daily" => "Per day",
               "referrals" => "Referrals", "events" => "Events", "jobs" => "Scheduled jobs", "tables" => "Table sizes" }.freeze
    # One report may run this long (nothing is ever pruned, so "all time" over a large events table can be slow); then it says so instead of tying up the server.
    STATEMENT_TIMEOUT = "20s".freeze
    MIN_CELL = 5
    SUPPRESSED = "<5".freeze
    CACHE_SECONDS = 5.minutes
    VERSION_KEY = "admin-analytics:version".freeze

    # kind: count, percent, hours, bytes, time (an ISO 8601 UTC string), status (words on a badge) or text.
    Column = Data.define(:key, :label, :kind) do
      def initialize(key:, label:, kind:) = super(key: key.to_sym, label: label, kind: kind)

      def numeric? = %i[count percent hours bytes].include?(kind)
    end
    Table = Data.define(:key, :title, :description, :columns, :rows, :note)

    # The period a report covers: whole UTC days up to and including today.
    Window = Data.define(:key, :today) do
      def days = key == "all" ? nil : Integer(key)
      def first_day = days ? today - (days - 1) : nil
      def since = first_day ? first_day.in_time_zone("UTC") : Time.utc(2000, 1, 1)
      def label = days ? "last #{days} days" : "all time"
    end

    class << self
      def range(value) = RANGES.include?(value.to_s) ? value.to_s : DEFAULT_RANGE

      def window(range, today: Time.current.utc.to_date) = Window.new(key: self.range(range), today: today)

      def key?(key) = KEYS.include?(key.to_s)

      def label(key) = LABELS.fetch(key.to_s)

      # Every report, in menu order (each one cached on its own). The page builds one at a time; this is for tests and tools.
      def all(range: DEFAULT_RANGE, today: Time.current.utc.to_date) = KEYS.map { |key| fetch(key, range: range, today: today) }

      def fetch(key, range: DEFAULT_RANGE, today: Time.current.utc.to_date)
        raise ArgumentError, "unknown report #{key.to_s.first(20).inspect}" unless key?(key)

        window = window(range, today: today)
        Rails.cache.fetch([ "admin-analytics", Rails.cache.read(VERSION_KEY), key.to_s, window.key, today.iso8601 ], expires_in: CACHE_SECONDS) do
          build(key, window)
        end
      end

      # The refresh button: every cached report is stale from now on (a new version in the key; nothing is deleted from the cache by pattern).
      def expire! = Rails.cache.write(VERSION_KEY, SecureRandom.hex(4))

      def csv(table)
        CSV.generate do |out|
          out << table.columns.map(&:key)
          table.rows.each { |row| out << table.columns.map { |column| csv_cell(row[column.key]) } }
        end
      end

      def json(table, range:)
        { report: table.key, title: table.title, range: range, generated_at: Time.current.utc.iso8601, note: table.note,
          columns: table.columns.map { |column| { key: column.key, label: column.label } },
          rows: table.rows.map { |row| table.columns.to_h { |column| [ column.key, row[column.key] ] } } }
      end

      # "<5" for one to four; zero stays zero (nothing to protect) and so does anything from five up.
      def suppress(count) = count.to_i.between?(1, MIN_CELL - 1) ? SUPPRESSED : count.to_i

      def percent(part, whole) = whole.to_i.positive? && part.is_a?(Numeric) ? (part * 100.0 / whole).round(1) : nil

      private

      def build(key, window)
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '#{STATEMENT_TIMEOUT}'")
          Sections.new(window).public_send(key)
        end
      rescue ActiveRecord::QueryCanceled
        Table.new(key: key.to_s, title: label(key), description: "", columns: [ Column.new(key: :step, label: "Step", kind: :text) ], rows: [],
                  note: "This report took longer than #{STATEMENT_TIMEOUT} and was stopped. Choose a shorter period.")
      end

      # Words in a download can never start a spreadsheet formula.
      def csv_cell(value) = value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/) ? "'#{value}" : value
    end
  end
end
