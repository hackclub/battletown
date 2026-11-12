require "test_helper"
require_relative "../../support/orders_helper"
require "csv"

class Orders::CsvExportTest < ActiveSupport::TestCase
  include OrdersTestHelper

  setup do
    setup_orders_world
    @buyer.update_columns(display_name: "Pat Buyer", slack_id: "U0EXPORT01")
  end
  teardown { teardown_orders_world }

  def export(scope: Order.queue_order, **options) = Orders::CsvExport.new(scope: scope, **options)

  def parse(export) = CSV.parse(export.each_line.to_a.join, headers: true)

  test "the default columns hold no name, no Slack id, no email and no tracking number" do
    order_in("shipped")
    table = parse(export)
    assert_equal %w[order_id created_at status item_name coins kind tracking_carrier age_days], table.headers
    row = table.first
    assert_equal [ "shipped", "Battletown T-shirt", "50", "purchase", "ups", "0" ], row.values_at("status", "item_name", "coins", "kind", "tracking_carrier", "age_days")
    text = export.each_line.to_a.join
    assert_no_match(/Pat Buyer|U0EXPORT01|@|1Z999AA10123456784/, text)
  end

  test "contact columns are added only on request" do
    order_in("requested")
    table = parse(export(include_contact: true))
    assert_equal %w[display_name slack_id], table.headers.last(2)
    assert_equal [ "Pat Buyer", "U0EXPORT01" ], table.first.values_at("display_name", "slack_id")
  end

  test "every cell is quoted, lines end with CRLF, and line breaks inside a cell become spaces" do
    order = order_for
    order.update_columns(prize_name: "Two\nline\r\nname")
    lines = export.each_line.to_a
    assert lines.all? { |line| line.end_with?("\r\n") }
    assert_includes lines.last, %("Two line name")
    assert lines.last.split(",").all? { |cell| cell.start_with?('"') }
  end

  test "formula injection is neutralised in every cell, with and without spaces in front" do
    %w[= + - @].each do |sign|
      assert_equal %("'#{sign}cmd|' /C calc'!A0"), Orders::CsvExport.cell("#{sign}cmd|' /C calc'!A0"), sign
    end
    assert_equal %("'\tcmd"), Orders::CsvExport.cell("\tcmd")
    assert_equal %("'  =1+1"), Orders::CsvExport.cell("  =1+1")
    assert_equal %("safe = fine"), Orders::CsvExport.cell("safe = fine")
    assert_equal %("5"), Orders::CsvExport.cell(5)
    assert_equal %("say ""hi"""), Orders::CsvExport.cell('say "hi"')

    order = order_for
    order.update_columns(prize_name: "=HYPERLINK(\"http://evil.test\")")
    @buyer.update_columns(display_name: "+SUM(A1)", slack_id: "@everyone")
    text = export(include_contact: true).each_line.to_a.join
    assert_includes text, %("'=HYPERLINK(""http://evil.test"")")
    assert_includes text, %("'+SUM(A1)")
    assert_includes text, %("'@everyone")
    assert_no_match(/(^|,)"[=+@-]/, text)
  end

  test "the cap cuts the rows and says so" do
    give_coins(@buyer, 1000)
    3.times { order_for(@buyer, prize: "custom_sticker") }
    capped = export(max: 2)
    assert_equal 2, parse(capped).size
    assert_predicate capped, :truncated?
    assert_equal 2, capped.row_count
    whole = export(max: 10)
    assert_not whole.truncated?
    assert_equal Order.count, whole.row_count
  end

  test "the audit metadata has the filter, the options and the row count, and no names" do
    order_for
    metadata = export(scope: Order.where(status: "requested"), include_contact: true).audit_metadata({ status: "requested", kind: nil, q: "T-shirt" })
    assert_equal({ filter_status: "requested", filter_kind: nil, filter_query: "T-shirt", include_contact: true, row_count: 1, truncated: false }, metadata)
    assert_nil export.audit_metadata({ q: "someone@example.test" })[:filter_query], "a search that looks like an email is not recorded"
    assert_nil export.audit_metadata({ q: "x" * 61 })[:filter_query]
  end

  test "rows come in queue order: requested, on hold, shipped, then the rest" do
    done = order_in("fulfilled")
    shipped = order_in("shipped")
    held = order_in("on_hold")
    waiting = order_in("requested")
    ids = parse(export).map { |row| row["order_id"].to_i }
    assert_equal [ waiting.id, held.id, shipped.id, done.id ], ids
  end

  test "a big export streams in slices without loading every row at once" do
    ids = Array.new(3) { order_for(@buyer, prize: "custom_sticker").id }
    slices = []
    callback = ->(*, payload) { slices << payload[:sql] if payload[:sql].match?(/FROM "orders" WHERE "orders"."id" (IN|= ANY|=)/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      stub_slice(2) { parse(export) }
    end
    assert_operator slices.size, :>=, 2
    assert_equal ids.size, Order.where(id: ids).count
  end

  private

  def stub_slice(size)
    original = Orders::CsvExport::SLICE
    Orders::CsvExport.send(:remove_const, :SLICE)
    Orders::CsvExport.const_set(:SLICE, size)
    yield
  ensure
    Orders::CsvExport.send(:remove_const, :SLICE)
    Orders::CsvExport.const_set(:SLICE, original)
  end
end
