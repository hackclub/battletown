require "test_helper"

# The pieces of Analytics::Report that need no database rows: small-cell hiding, percentages, periods and the CSV and JSON shape.
class AnalyticsReportTest < ActiveSupport::TestCase
  def table(rows)
    Analytics::Report::Table.new(key: "demo", title: "Demo", description: "", note: nil, rows: rows,
                                 columns: [ Analytics::Report::Column.new(key: "word", label: "Word", kind: :text), Analytics::Report::Column.new(key: :n, label: "N", kind: :count) ])
  end

  test "one to four is hidden, zero and five or more are not" do
    assert_equal [ 0, "<5", "<5", "<5", "<5", 5, 600 ], [ 0, 1, 2, 3, 4, 5, 600 ].map { |count| Analytics::Report.suppress(count) }
    assert_equal "<5", Analytics::Report.suppress(1.0)
    assert_equal 0, Analytics::Report.suppress(nil)
  end

  test "a percentage needs two real numbers" do
    assert_equal 33.3, Analytics::Report.percent(1, 3)
    assert_nil Analytics::Report.percent(1, 0)
    assert_nil Analytics::Report.percent("<5", 10)
    assert_nil Analytics::Report.percent(5, "<5")
  end

  test "an unknown period is the default; all time has no first day" do
    today = Date.new(2026, 11, 26)
    assert_equal "7", Analytics::Report.range("1; drop")
    assert_equal "all", Analytics::Report.range("all")
    window = Analytics::Report.window("30", today: today)
    assert_equal [ Date.new(2026, 10, 28), "last 30 days" ], [ window.first_day, window.label ]
    assert_equal Time.utc(2026, 10, 28), window.since
    all = Analytics::Report.window("all", today: today)
    assert_nil all.first_day
    assert_equal "all time", all.label
  end

  test "an unknown report is refused" do
    assert_raises(ArgumentError) { Analytics::Report.fetch("users") }
    assert_not Analytics::Report.key?("users; drop")
  end

  test "the CSV has the column keys as its header, one line a row, and a word can never start a formula" do
    csv = CSV.parse(Analytics::Report.csv(table([ { word: "=SUM(A1)", n: 3 }, { word: "-1+1", n: "<5" }, { word: "plain", n: nil } ])))
    assert_equal [ %w[word n], [ "'=SUM(A1)", "3" ], [ "'-1+1", "<5" ], [ "plain", nil ] ], csv
  end

  test "the JSON carries the report, the period, the columns and the rows by key" do
    json = Analytics::Report.json(table([ { word: "a", n: 1, extra: "not a column" } ]), range: "7")
    assert_equal({ report: "demo", range: "7", columns: [ { key: :word, label: "Word" }, { key: :n, label: "N" } ], rows: [ { word: "a", n: 1 } ] },
                 json.slice(:report, :range, :columns, :rows))
  end
end
