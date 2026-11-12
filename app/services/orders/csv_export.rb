module Orders
  # The staff CSV of orders (Admin::OrdersController#export). One row per order, newest-queue order, at most `export_max_rows` rows.
  # Columns: order id, created_at (UTC), status, item name, coins, kind, tracking carrier, age in days. The person's display name and
  # Slack id are added only when `include_contact` is true, and never an email, address or tracking number. Every cell is quoted,
  # line breaks inside a cell become spaces, and a cell that starts with = + - @ (or a tab or carriage return, even after spaces) gets a
  # leading apostrophe so a spreadsheet cannot run it as a formula. The rows are read in slices of ids, so a large export never holds
  # them all in memory; `each_line` is an Enumerator the controller streams.
  class CsvExport
    BASE_COLUMNS = %w[order_id created_at status item_name coins kind tracking_carrier age_days].freeze
    CONTACT_COLUMNS = %w[display_name slack_id].freeze
    SLICE = 500
    FORMULA_START = /\A[[:space:]]*[=+\-@\t\r]/

    # A cell as it goes into the file: text, quoted, safe from formula injection.
    def self.cell(value)
      text = value.to_s.gsub(/[\r\n]+/, " ")
      text = "'#{text}" if text.match?(FORMULA_START)
      %("#{text.gsub('"', '""')}")
    end

    attr_reader :include_contact

    def initialize(scope:, include_contact: false, max: Config.current.export_max_rows, now: Time.current)
      @scope = scope
      @include_contact = include_contact
      @max = max
      @now = now
    end

    def columns = include_contact ? BASE_COLUMNS + CONTACT_COLUMNS : BASE_COLUMNS

    # The ids to export, in queue order, cut at the cap. Computed once.
    def ids
      @ids ||= @scope.limit(@max + 1).pluck(:id)
    end

    def truncated? = ids.size > @max

    def row_count = [ ids.size, @max ].min

    # What goes into the audit row: the filter and how many rows left the building (no names, no ids of people).
    def audit_metadata(filters)
      { filter_status: filters[:status], filter_kind: filters[:kind], filter_query: audit_query(filters[:q]), include_contact: include_contact,
        row_count: row_count, truncated: truncated? }
    end

    def each_line
      Enumerator.new do |lines|
        lines << line(columns)
        ids.first(@max).each_slice(SLICE) do |slice|
          orders = Order.includes(:user).where(id: slice).index_by(&:id)
          slice.each { |id| lines << line(values(orders.fetch(id))) if orders.key?(id) }
        end
      end
    end

    private

    def line(cells) = "#{cells.map { |cell| self.class.cell(cell) }.join(',')}\r\n"

    def values(order)
      row = [ order.id, order.created_at.utc.iso8601, order.status, order.prize_name, order.coins, order.kind, order.tracking_carrier,
              order.age_days(@now) ]
      include_contact ? row + [ order.user.display_name, order.user.slack_id ] : row
    end

    # A search term goes in the audit row only when it looks like an item name or order number (never an email or a long string).
    def audit_query(term)
      term if term.to_s.match?(/\A[\p{L}\p{N} #._'-]{1,60}\z/)
    end
  end
end
