require "test_helper"

class TrackingLinkHelperTest < ActionView::TestCase
  include TrackingLinkHelper

  test "the helper always adds noopener noreferrer nofollow and opens in a new tab, and escapes the number" do
    order = Order.new(tracking_carrier: "ups", tracking_number: "1Z999AA10123456784")
    html = tracking_summary(order)
    assert_dom_equal_selector html, "a[href='https://www.ups.com/track?tracknum=1Z999AA10123456784'][rel='noopener noreferrer nofollow'][target='_blank']"
    assert_includes html, "1Z999AA10123456784"
  end

  test "the helper shows plain text without a link for carriers without a page, and escapes odd labels" do
    order = Order.new(tracking_carrier: "other", tracking_number: "ABC123456", tracking_label: "<b>Bold</b>")
    html = tracking_summary(order)
    assert_no_match(/<a /, html)
    assert_no_match(/<b>Bold/, html)
    assert_includes html, "&lt;b&gt;Bold&lt;/b&gt;"
    assert_nil tracking_summary(Order.new)
  end

  private

  def assert_dom_equal_selector(html, selector)
    assert_not_empty Nokogiri::HTML.fragment(html.to_s).css(selector), "expected #{selector} in #{html}"
  end
end
