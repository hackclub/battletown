require "net/http"

module Privacy
  # The public keys Hack Club's data-deletion service signs its tokens with (a JWKS document). Fetched from one
  # configured URL only, cached in process for 5 minutes, and refetched when a token names an unknown `kid`, but
  # never more often than every 30 seconds, so a caller cannot make this app hammer the key server. Any failure to
  # get keys raises Unavailable (the controller answers 503 and the caller retries later).
  class Jwks
    DEFAULT_URL = "https://yeet.hackclub.com/.well-known/jwks.json".freeze
    CACHE_TTL = 5.minutes
    MIN_REFETCH_INTERVAL = 30.seconds
    MAX_BYTES = 64.kilobytes
    MAX_KEYS = 20

    class Unavailable < StandardError; end

    # The default fetcher. https only (plain http is allowed for a local key server in development), short
    # timeouts, no redirects, a size cap. Returns the response body.
    class HttpFetcher
      def call(url)
        uri = URI.parse(url)
        raise Unavailable, "unsupported JWKS URL scheme" unless uri.is_a?(URI::HTTPS) || (uri.is_a?(URI::HTTP) && Rails.env.development?)

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 5, write_timeout: 5) do |http|
          http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
        end
        raise Unavailable, "JWKS responded #{response.code}" unless response.is_a?(Net::HTTPOK)
        raise Unavailable, "JWKS response too large" if response.body.to_s.bytesize > MAX_BYTES

        response.body
      rescue URI::InvalidURIError, SystemCallError, SocketError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError => e
        raise Unavailable, "JWKS fetch failed (#{e.class})"
      end
    end

    class << self
      # The process-wide instance. Tests swap it with `Privacy::Jwks.current = Privacy::Jwks.new(fetcher: ...)`.
      attr_writer :current

      def current
        @current ||= new
      end

      def url = ENV["PRIVACY_JWKS_URL"].presence || DEFAULT_URL
    end

    def initialize(url: nil, fetcher: HttpFetcher.new, clock: -> { Time.current })
      @url = url
      @fetcher = fetcher
      @clock = clock
      @mutex = Mutex.new
      @keys = {}
      @fetched_at = nil
      @attempted_at = nil
    end

    # The OpenSSL public key for `kid`, or nil when the key server does not list it. Raises Unavailable when keys
    # are needed and cannot be fetched.
    def key_for(kid)
      @mutex.synchronize do
        refresh if stale? && may_fetch?
        raise Unavailable, "no usable JWKS" if stale?

        unless @keys.key?(kid)
          refresh if may_fetch?
          raise Unavailable, "no usable JWKS" if stale?
        end
        @keys[kid]
      end
    end

    private

    def stale? = @fetched_at.nil? || @clock.call - @fetched_at >= CACHE_TTL

    def may_fetch? = @attempted_at.nil? || @clock.call - @attempted_at >= MIN_REFETCH_INTERVAL

    def refresh
      @attempted_at = @clock.call
      @keys = parse(@fetcher.call(@url || self.class.url))
      @fetched_at = @attempted_at
    rescue Unavailable
      raise
    rescue JSON::ParserError, TypeError, KeyError => e
      raise Unavailable, "JWKS unreadable (#{e.class})"
    end

    # Keeps only usable P-256 signing keys that have a kid; a malformed entry is skipped, not fatal.
    def parse(body)
      document = JSON.parse(body)
      keys = document.is_a?(Hash) ? document["keys"] : nil
      raise TypeError, "keys is not a list" unless keys.is_a?(Array)

      keys.first(MAX_KEYS).each_with_object({}) do |jwk, found|
        next unless jwk.is_a?(Hash) && jwk["kty"] == "EC" && jwk["crv"] == "P-256" && jwk["kid"].is_a?(String)
        next if jwk["use"] && jwk["use"] != "sig"

        found[jwk["kid"]] = JWT::JWK.new(jwk.slice("kty", "crv", "x", "y", "kid")).verify_key
      rescue JWT::JWKError, OpenSSL::OpenSSLError, ArgumentError, TypeError
        next
      end
    end
  end
end
