require "test_helper"
require_relative "../../support/privacy_helper"

class PrivacyTokenVerifierTest < ActiveSupport::TestCase
  include PrivacyHelper

  setup { @verifier = Privacy::TokenVerifier.new(jwks: Privacy::Jwks.new(fetcher: privacy_fetcher), audience: "battletown") }

  test "a good token yields its claims, with emails lowercased and trimmed" do
    token = privacy_token(privacy_claims(jti: "j1", request_id: "r1", action: "export", dry_run: true,
                                         subject: { emails: [ " A@Example.COM ", "a@example.com", "" ], slack_id: "U1", identity_id: "ident!x" }))
    claims = @verifier.verify!(token)

    assert_equal [ "j1", "r1", "export", true ], [ claims.jti, claims.request_id, claims.action, claims.dry_run ]
    assert_equal [ "a@example.com" ], claims.subject.emails
    assert_equal [ "U1", "ident!x" ], [ claims.subject.slack_id, claims.subject.identity_id ]
  end

  test "null Slack and identity ids and a missing emails list are fine" do
    claims = @verifier.verify!(privacy_token(privacy_claims(subject: { slack_id: nil })))
    assert_equal [], claims.subject.emails
    assert_nil claims.subject.slack_id
    assert_nil claims.subject.identity_id
  end

  test "the audience is a configuration value defaulting to battletown" do
    assert_equal "battletown", Privacy::TokenVerifier.audience
    ENV["PRIVACY_AUDIENCE"] = "battletown-staging"
    assert_equal "battletown-staging", Privacy::TokenVerifier.audience
    verifier = Privacy::TokenVerifier.new(jwks: Privacy::Jwks.new(fetcher: privacy_fetcher))
    assert verifier.verify!(privacy_token(privacy_claims(aud: "battletown-staging")))
    assert_raises(Privacy::TokenVerifier::Invalid) { verifier.verify!(privacy_token(privacy_claims(aud: "battletown"))) }
  ensure
    ENV.delete("PRIVACY_AUDIENCE")
  end

  test "every failure is the same bare Invalid error and never mentions the token" do
    token = privacy_token(privacy_claims(aud: "other"))
    error = assert_raises(Privacy::TokenVerifier::Invalid) { @verifier.verify!(token) }
    assert_not_includes error.message, token
    assert_equal "Privacy::TokenVerifier::Invalid", error.message
    assert_nil error.cause
  end

  test "a nil or non-string token is Invalid" do
    [ nil, 12, "", [] ].each { |value| assert_raises(Privacy::TokenVerifier::Invalid) { @verifier.verify!(value) } }
  end

  test "a key server outage is not Invalid" do
    privacy_fetcher.fails = true
    assert_raises(Privacy::Jwks::Unavailable) { @verifier.verify!(privacy_token) }
  end

  test "too many emails are rejected" do
    emails = Array.new(51) { |i| "e#{i}@example.com" }
    assert_raises(Privacy::TokenVerifier::Invalid) { @verifier.verify!(privacy_token(privacy_claims(subject: { emails: emails }))) }
  end
end
