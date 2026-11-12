require "openssl"
require_relative "fake_hackatime"

# A tiny in-process stand-in for auth.hackclub.com, served over a real local socket so the real OpenID Connect strategy runs
# (discovery, state, nonce, PKCE, a signed ID token) and the real Net::HTTP code calls GET /api/v1/me and POST /oauth/revoke.
# No network beyond 127.0.0.1. Example data only: nothing here is a real person, street or number.
#
#   fake = FakeHca.new(sub: user.hca_uid)
#   fake.me = [ 200, { "identity" => { "addresses" => [ ... ] }, "scopes" => %w[openid address] } ]
#   fake.requests_for("POST", "/oauth/revoke")
class FakeHca < FakeHackatime
  KEY = OpenSSL::PKey::RSA.generate(2048)
  KID = "fake-key-1".freeze
  CLIENT_ID = "test-hca-client-id".freeze
  ACCESS_TOKEN = "idntk.fake-access-token-0123456789".freeze
  REFRESH_TOKEN = "idnrf.fake-refresh-token-0123456789".freeze

  attr_accessor :me, :sub, :id_token_nonce, :challenge, :token_status

  def initialize(sub:)
    super()
    @sub = sub
    @me = [ 200, { "identity" => { "id" => sub, "addresses" => [] }, "scopes" => %w[openid address] } ]
    @token_status = 200
    install
  end

  def self.address(id, **attributes)
    { "id" => id, "first_name" => "Pat", "last_name" => "Example", "line_1" => "#{id.delete_prefix('addr_').capitalize} Example Street", "line_2" => nil,
      "city" => "Exampleville", "state" => "EX", "postal_code" => "00000", "country" => "US", "phone_number" => "+15555550123", "primary" => false }
      .merge(attributes.transform_keys(&:to_s)).compact
  end

  def me_with(*addresses, scopes: %w[openid address])
    @me = [ 200, { "identity" => { "id" => sub, "addresses" => addresses }, "scopes" => scopes } ]
  end

  def revoked_tokens = requests_for("POST", "/oauth/revoke").map { |request| request.form["token"] }

  private

  def install
    on("GET", "/.well-known/openid-configuration") { |_req| [ 200, discovery ] }
    on("GET", "/oauth/discovery/keys") { |_req| [ 200, { "keys" => [ JSON::JWK.new(KEY.public_key, kid: KID, use: "sig", alg: "RS256") ] } ] }
    on("POST", "/oauth/token") { |req| token_response(req) }
    on("GET", "/api/v1/me") { |req| req.headers["authorization"] == "Bearer #{ACCESS_TOKEN}" ? @me : [ 401, { "error" => "invalid_auth" } ] }
    on("POST", "/oauth/revoke") { |_req| [ 200, {} ] }
  end

  def discovery
    { "issuer" => url, "authorization_endpoint" => "#{url}/oauth/authorize", "token_endpoint" => "#{url}/oauth/token",
      "userinfo_endpoint" => "#{url}/oauth/userinfo", "jwks_uri" => "#{url}/oauth/discovery/keys", "response_types_supported" => [ "code" ],
      "subject_types_supported" => [ "public" ], "id_token_signing_alg_values_supported" => [ "RS256" ], "scopes_supported" => %w[openid address] }
  end

  def token_response(req)
    return [ @token_status, { "error" => "invalid_grant" } ] unless @token_status == 200
    return [ 400, { "error" => "invalid_grant" } ] unless req.form["code"] == "good-code" && FakeHackatime.pkce_matches?(req.form["code_verifier"], challenge)

    claims = { iss: url, sub: sub, aud: CLIENT_ID, exp: 10.minutes.from_now.to_i, iat: Time.now.to_i, nonce: id_token_nonce }
    jwt = JSON::JWT.new(claims)
    jwt.kid = KID
    id_token = jwt.sign(KEY, :RS256).to_s
    [ 200, { "access_token" => ACCESS_TOKEN, "refresh_token" => REFRESH_TOKEN, "token_type" => "Bearer", "expires_in" => 3600, "scope" => "openid address",
             "id_token" => id_token } ]
  end
end
