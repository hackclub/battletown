require "test_helper"

class IconHelperTest < ActionView::TestCase
  test "an icon is a decorative inline SVG sized in em, with its own class" do
    html = icon(:check, class: "toggle__check")
    assert_includes html, "<svg"
    assert_includes html, 'class="icon icon--check toggle__check"'
    assert_includes html, 'viewBox="0 0 24 24"'
    assert_includes html, 'aria-hidden="true"'
    assert_includes html, 'focusable="false"'
  end

  test "an unknown icon name fails loudly" do
    assert_raises(ArgumentError) { icon(:sparkle) }
  end

  test "every status the order pages show has an icon" do
    OrderStatusHelper::STAFF_STATUS_TEXT.each_key { |status| assert_includes OrderStatusHelper::ORDER_STATUS_ICONS, status }
  end
end
