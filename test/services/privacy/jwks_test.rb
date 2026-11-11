require "test_helper"
require_relative "../../support/privacy_helper"

class PrivacyJwksTest < ActiveSupport::TestCase
  include PrivacyHelper

  setup { @now = Time.utc(2030, 1, 1, 12, 0, 0) }

  def jwks(fetcher = privacy_fetcher)
    Privacy::Jwks.new(fetcher: fetcher, clock: -> { @now })
  end

  test "returns the key for a known kid and caches the document for 5 minutes" do
    keys = jwks
    assert_equal PrivacyHelper::KEY.public_to_der, keys.key_for(PrivacyHelper::KID).public_to_der
    keys.key_for(PrivacyHelper::KID)
    @now += 4.minutes
    keys.key_for(PrivacyHelper::KID)
    assert_equal 1, privacy_fetcher.calls

    @now += 2.minutes
    keys.key_for(PrivacyHelper::KID)
    assert_equal 2, privacy_fetcher.calls
  end

  test "an unknown kid triggers one refetch, then none for 30 seconds" do
    keys = jwks
    keys.key_for(PrivacyHelper::KID)
    assert_equal 1, privacy_fetcher.calls

    @now += 31.seconds
    assert_nil keys.key_for("rotated")
    assert_equal 2, privacy_fetcher.calls

    @now += 10.seconds
    assert_nil keys.key_for("another")
    assert_nil keys.key_for("rotated")
    assert_equal 2, privacy_fetcher.calls

    @now += 21.seconds
    privacy_fetcher.keys += [ [ OpenSSL::PKey::EC.generate("prime256v1"), "rotated" ] ]
    assert keys.key_for("rotated")
    assert_equal 3, privacy_fetcher.calls
  end

  test "a failed fetch raises Unavailable and is not retried for 30 seconds" do
    privacy_fetcher.fails = true
    keys = jwks
    assert_raises(Privacy::Jwks::Unavailable) { keys.key_for(PrivacyHelper::KID) }
    assert_raises(Privacy::Jwks::Unavailable) { keys.key_for(PrivacyHelper::KID) }
    assert_equal 1, privacy_fetcher.calls

    privacy_fetcher.fails = false
    @now += 31.seconds
    assert keys.key_for(PrivacyHelper::KID)
  end

  test "expired keys are not used when the key server cannot be reached" do
    keys = jwks
    keys.key_for(PrivacyHelper::KID)
    privacy_fetcher.fails = true
    @now += 6.minutes
    assert_raises(Privacy::Jwks::Unavailable) { keys.key_for(PrivacyHelper::KID) }
  end

  test "garbage documents are Unavailable and unusable keys are skipped" do
    [ "not json", "{}", '{"keys":"x"}', "null", "[]" ].each do |body|
      assert_raises(Privacy::Jwks::Unavailable, body) { jwks(->(_url) { body }).key_for("k") }
    end

    rsa = JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), kid: "rsa").export
    other_curve = JWT::JWK.new(OpenSSL::PKey::EC.generate("secp384r1"), kid: "p384").export
    good = JWT::JWK.new(PrivacyHelper::KEY, kid: "good").export
    body = { keys: [ rsa, other_curve, { kty: "EC", crv: "P-256", kid: "broken", x: "AA", y: "AA" }, "junk", good.merge(use: "enc").merge(kid: "enc"), good ] }.to_json
    keys = jwks(->(_url) { body })
    assert keys.key_for("good")
    %w[rsa p384 broken enc].each { |kid| assert_nil keys.key_for(kid) }
  end

  test "the URL defaults to the real service and can be overridden" do
    assert_equal "https://yeet.hackclub.com/.well-known/jwks.json", Privacy::Jwks.url
    ENV["PRIVACY_JWKS_URL"] = "https://keys.example.test/jwks.json"
    assert_equal "https://keys.example.test/jwks.json", Privacy::Jwks.url
  ensure
    ENV.delete("PRIVACY_JWKS_URL")
  end

  test "the default fetcher only speaks https outside development and never touches the network here" do
    fetcher = Privacy::Jwks::HttpFetcher.new
    [ "http://yeet.hackclub.com/jwks.json", "file:///etc/passwd", "ftp://example.test/x", "not a url" ].each do |url|
      assert_raises(Privacy::Jwks::Unavailable, url) { fetcher.call(url) }
    end
  end
end
