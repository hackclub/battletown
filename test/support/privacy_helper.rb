require "openssl"

# Shared helpers for the data-deletion (yeet) tests. Nothing here touches the network: a real ES256 key pair is
# generated in process and the JWKS fetch is replaced by a stub (Privacy::Jwks takes a fetcher).
module PrivacyHelper
  KEY = OpenSSL::PKey::EC.generate("prime256v1")
  KID = "test-key-1".freeze
  AUDIENCE = "battletown".freeze

  # Stands in for the HTTP fetch of the JWKS document. `body` is what the key server would return; `fails` makes it
  # unreachable. Counts the fetches so tests can assert the cache and the refetch throttle.
  class FakeJwksFetcher
    attr_reader :calls
    attr_accessor :keys, :fails

    def initialize(keys: [ [ KEY, KID ] ], fails: false)
      @keys = keys
      @fails = fails
      @calls = 0
    end

    def call(_url)
      @calls += 1
      raise Privacy::Jwks::Unavailable, "unreachable" if fails

      { keys: keys.map { |key, kid| JWT::JWK.new(key, kid: kid).export } }.to_json
    end
  end

  def privacy_fetcher
    @privacy_fetcher ||= FakeJwksFetcher.new
  end

  def install_privacy_jwks(fetcher = privacy_fetcher)
    Privacy::Jwks.current = Privacy::Jwks.new(fetcher: fetcher)
  end

  def uninstall_privacy_jwks
    Privacy::Jwks.current = nil
  end

  def privacy_claims(overrides = {})
    now = Time.now.to_i
    { iss: "hackclub-privacy", aud: AUDIENCE, iat: now, exp: now + 240, jti: SecureRandom.uuid,
      request_id: "req-#{SecureRandom.hex(4)}", action: "delete", dry_run: false,
      subject: { emails: [], slack_id: nil, identity_id: nil } }.merge(overrides).compact # an override of nil omits the claim
  end

  # An ES256 token signed by the test key; `header` entries override the defaults, `key:`/`alg:` change the signer.
  def privacy_token(claims = privacy_claims, key: KEY, alg: "ES256", header: {})
    JWT.encode(claims, key, alg, { kid: KID, typ: "JWT" }.merge(header))
  end

  def privacy_headers(token)
    { "Authorization" => "Bearer #{token}", "Accept" => "application/json" }
  end

  # Calls the endpoint the way the yeet service does: no body, bearer token, JSON.
  def privacy_call(action, token, **options)
    post "/api/privacy/#{action}", headers: privacy_headers(token), **options
  end

  # Replaces `object.name` with `impl` for the block (Minitest 6 no longer ships stub).
  def stub_method(object, name, impl)
    original = object.method(name)
    object.define_singleton_method(name) { |*args, **kwargs, &block| impl.call(*args, **kwargs, &block) }
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def privacy_subject(emails: [], slack_id: nil, identity_id: nil)
    { emails: emails, slack_id: slack_id, identity_id: identity_id }
  end
end
