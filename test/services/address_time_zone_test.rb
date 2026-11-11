require "test_helper"

class AddressTimeZoneTest < ActiveSupport::TestCase
  def zone(address) = AddressTimeZone.call("address" => address)

  test "US states by code and by name, case-insensitively" do
    assert_equal "America/New_York", zone("country" => "US", "region" => "NY")
    assert_equal "America/Los_Angeles", zone("country" => "US", "region" => "California")
    assert_equal "America/Chicago", zone("country" => "us", "region" => "il")
    assert_equal "America/Denver", zone("country" => "US", "region" => "  colorado ")
    assert_equal "America/Phoenix", zone("country" => "US", "region" => "AZ")
    assert_equal "Pacific/Honolulu", zone("country" => "US", "region" => "Hawaii")
    assert_equal "America/New_York", zone("country" => "US", "region" => "Washington, D.C.")
    assert_equal "America/Los_Angeles", zone("country" => "US", "region" => "Washington")
    assert_equal "America/New_York", zone("country" => "US", "region" => "US-NY")
  end

  test "split states use the zone covering most of the population" do
    assert_equal "America/Chicago", zone("country" => "US", "region" => "TX")
    assert_equal "America/New_York", zone("country" => "US", "region" => "FL")
    assert_equal "America/New_York", zone("country" => "US", "region" => "Indiana")
    assert_equal "America/Denver", zone("country" => "US", "region" => "ID")
  end

  test "Canadian provinces" do
    assert_equal "America/Toronto", zone("country" => "CA", "region" => "ON")
    assert_equal "America/Toronto", zone("country" => "CA", "region" => "Quebec")
    assert_equal "America/Edmonton", zone("country" => "CA", "region" => "Alberta")
    assert_equal "America/Halifax", zone("country" => "Canada", "region" => "Nova Scotia")
  end

  test "Australian states, Brazilian states and Mexican states" do
    assert_equal "Australia/Sydney", zone("country" => "AU", "region" => "NSW")
    assert_equal "Australia/Perth", zone("country" => "AU", "region" => "Western Australia")
    assert_equal "America/Sao_Paulo", zone("country" => "BR", "region" => "São Paulo")
    assert_equal "America/Manaus", zone("country" => "BR", "region" => "AM")
    assert_equal "America/Mexico_City", zone("country" => "MX", "region" => "Ciudad de México")
    assert_equal "America/Cancun", zone("country" => "MX", "region" => "Quintana Roo")
  end

  test "single-zone countries need no region" do
    assert_equal "Europe/Paris", zone("country" => "FR")
    assert_equal "Asia/Tokyo", zone("country" => "JP", "region" => "Anything")
    assert_equal "Asia/Kolkata", zone("country" => "IN")
  end

  test "countries whose zones share rules need no region" do
    assert_equal "Europe/Berlin", zone("country" => "DE")
  end

  test "country names and alpha-3 codes are normalised" do
    [ "United States", "united states of america", "USA", "U.S.", "America" ].each do |country|
      assert_equal "America/New_York", zone("country" => country, "region" => "NY"), country
    end
    assert_equal "Europe/London", zone("country" => "United Kingdom")
    assert_equal "Europe/London", zone("country" => "UK")
    assert_equal "Europe/Paris", zone("country" => "France")
    assert_equal "Asia/Tokyo", zone("country" => "Japan")
  end

  test "multi-zone countries without a usable region return nil" do
    assert_nil zone("country" => "US")
    assert_nil zone("country" => "US", "region" => "")
    assert_nil zone("country" => "US", "region" => "Atlantis")
    assert_nil zone("country" => "CA", "region" => "Yukon")
    assert_nil zone("country" => "RU")
    assert_nil zone("country" => "NZ")
  end

  test "junk, nil and empty inputs return nil and never raise" do
    [ nil, "", "x", 42, [], {}, [ {} ], { "address" => nil }, { "address" => "1 Main St" }, { "address" => [] },
     { "address" => { "country" => "ZZ" } }, { "address" => { "country" => "Narnia" } },
     { "address" => { "country" => 12 } }, { "address" => { "country" => [ "US" ], "region" => { "a" => 1 } } },
     { "addresses" => [ nil, 1, "x" ] }, { "address" => { "country" => "US", "region" => "\u0000" * 500 } },
     Object.new ].each do |input|
      assert_nil AddressTimeZone.call(input), input.inspect
      assert_nil AddressTimeZone.zone_name(input), input.inspect
    end
  end

  test "the primary address is picked from an addresses array, else the first" do
    claims = { "addresses" => [
      { "country" => "FR" },
      { "country" => "US", "region" => "WA", "primary" => true },
      { "country" => "JP" }
    ] }
    assert_equal "America/Los_Angeles", AddressTimeZone.call(claims)

    claims = { "addresses" => [ { "country" => "FR" }, { "country" => "JP" } ] }
    assert_equal "Europe/Paris", AddressTimeZone.call(claims)

    flagged = { "addresses" => [ { "country" => "FR", "primary" => false }, { "country" => "JP", "primary" => "true" } ] }
    assert_equal "Asia/Tokyo", AddressTimeZone.call(flagged)

    assert_equal "Asia/Tokyo", AddressTimeZone.call("primary_address" => { "country" => "JP" }, "addresses" => [ { "country" => "FR" } ])
  end

  test "does not fall through to another address when the chosen one is unusable" do
    claims = { "addresses" => [ { "country" => "US", "primary" => true }, { "country" => "FR" } ] }
    assert_nil AddressTimeZone.call(claims)
  end

  test "string and symbol keys and nested mashes are accepted" do
    assert_equal "America/Chicago", AddressTimeZone.call(address: { country: "US", region: "TX" })
    assert_equal "America/Chicago", AddressTimeZone.call("address" => { country: "US", "region" => "TX" })
    mash = OmniAuth::AuthHash.new(address: { country: "US", region: "TX", street_address: "1 Main St" })
    assert_equal "America/Chicago", AddressTimeZone.call(mash)
    assert_equal "America/Chicago", AddressTimeZone.call(country: "US", state: "TX")
  end

  test "zone_name returns a name the User model accepts and the select uses" do
    valid = ActiveSupport::TimeZone.all.map(&:name)
    assert_equal "Eastern Time (US & Canada)", AddressTimeZone.zone_name("address" => { "country" => "US", "region" => "NY" })
    assert_equal "Eastern Time (US & Canada)", AddressTimeZone.zone_name("address" => { "country" => "CA", "region" => "ON" })
    assert_equal "Central Time (US & Canada)", AddressTimeZone.zone_name("address" => { "country" => "US", "region" => "TX" })
    assert_equal "Paris", AddressTimeZone.zone_name("address" => { "country" => "FR" })
    assert_equal "Kolkata", AddressTimeZone.zone_name("address" => { "country" => "IN" })
    assert_includes valid, AddressTimeZone.zone_name("address" => { "country" => "LU" })
  end

  test "every table entry is a real zone that has a Rails zone name" do
    valid = ActiveSupport::TimeZone.all.map(&:name)
    AddressTimeZone::REGIONS.each_value do |zones|
      zones.each_key do |iana|
        assert TZInfo::Timezone.get(iana)
        name = AddressTimeZone.rails_zone_name(iana)
        # A zone whose rules match no Rails zone (e.g. a recent tzdata change) is allowed: it yields nil.
        assert_includes valid, name if name
      end
    end
  end

  test "the input is not mutated" do
    claims = { "address" => { "country" => "US", "region" => "NY", "street_address" => "1 Main St" } }.freeze
    assert_equal "America/New_York", AddressTimeZone.call(claims)
  end
end
