require "test_helper"

class Orders::TrackingLinkTest < ActiveSupport::TestCase
  Link = Orders::TrackingLink

  def link(carrier, number, label = nil) = Link.build(carrier, number, label)

  test "known carriers map to their public https tracking page with the number encoded" do
    assert_equal "https://tools.usps.com/go/TrackConfirmAction?tLabels=9400100000000000000000", link("usps", "9400 1000 0000 0000 0000 00").url
    assert_equal "https://www.ups.com/track?tracknum=1Z999AA10123456784", link("ups", "1Z999AA10123456784").url
    assert_equal "https://www.fedex.com/fedextrack/?trknbr=794644790138", link("fedex", "794644790138").url
    assert_includes link("dhl", "JD0146000000").url, "tracking-id=JD0146000000"
    assert_includes link("royal_mail", "AB123456789GB").url, "AB123456789GB"
  end

  test "every link the config can make is https on a real host" do
    Orders::Config.current.carriers.each_value do |carrier|
      next unless carrier.url

      url = link(carrier.key, "ABC123456").url
      assert url.start_with?("https://"), carrier.key
      assert_nil URI.parse(url).userinfo, carrier.key
    end
  end

  test "post, other and unknown carriers show the number only" do
    %w[post other nobody].each do |carrier|
      result = link(carrier, "ABC 123-456")
      assert_nil result.url, carrier
      assert_not result.linked?, carrier
      assert_equal "ABC 123-456", result.number
    end
    assert_equal "Local courier", link("other", "ABC123456", "Local courier").carrier
    assert_equal "Other", link("other", "ABC123456").carrier
    assert_equal "Carrier", link("nobody", "ABC123456").carrier
  end

  test "an unsafe number never becomes a link, whatever the carrier" do
    [ "javascript:alert(1)", "1Z9\"><script>", "abc/../../x", "a b%0d%0aSet-Cookie", "http://evil.test/", "1Z999 AA1;rm", "x" * 61 ].each do |number|
      result = link("ups", number)
      assert_nil result.url, number
    end
  end

  test "a carrier whose address isn't https gets no link" do
    insecure = Orders::Carrier.new(key: "x", name: "X", url: "http://example.test/?n={number}")
    assert_nil Link.url_for(insecure, "ABC123456")
    scheme = Orders::Carrier.new(key: "x", name: "X", url: "javascript:alert({number})")
    assert_nil Link.url_for(scheme, "ABC123456")
    assert_nil Link.url_for(nil, "ABC123456")
  end

  test "an order without a tracking number has no tracking" do
    assert_nil Link.for(Order.new)
    assert_nil link("ups", "   ")
  end
end
