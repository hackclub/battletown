module Hca
  # GET /api/v1/me with a one-time access token, reduced to the person's saved addresses (identity.addresses[] and nothing else
  # of the response is read, kept or returned). Raises Hca::LookupError with a code (see Hca::LookupError); the token and the
  # response are never logged and never put in an error.
  #
  #   result = Hca::Me.addresses(token)   # => Hca::Me::Result(addresses: [Hca::Address, ...], skipped: 0)
  #
  # `skipped` counts addresses that came back but could not be used (no street, city, name or a real country).
  class Me
    MAX_ADDRESSES = 20
    Result = Data.define(:addresses, :skipped)

    def self.addresses(token, http: Http.new) = new(http: http).addresses(token)

    def initialize(http:)
      @http = http
    end

    def addresses(token)
      raise LookupError, :unauthorized if token.blank?

      response = @http.get("/api/v1/me", token: token)
      case response.status
      when 200 then parse(response.body)
      when 401 then raise LookupError, :unauthorized
      when 403, 404 then raise LookupError, :not_available
      when 429, 500..599 then raise LookupError, :unavailable
      else raise LookupError, :bad_response
      end
    end

    private

    def parse(body)
      data = JSON.parse(body)
      raise LookupError, :bad_response unless data.is_a?(Hash) && data["identity"].is_a?(Hash)

      raw = data["identity"]["addresses"]
      if raw.nil?
        # No `addresses` key: Hack Club Auth leaves it out when the grant lacks the `address` scope (or when there are none).
        scopes = data["scopes"]
        raise LookupError, :not_available if scopes.is_a?(Array) && scopes.exclude?("address")

        raw = []
      end
      raise LookupError, :bad_response unless raw.is_a?(Array)

      list = raw.first(MAX_ADDRESSES).map { |entry| Address.from_hca(entry) }
      Result.new(addresses: list.compact.sort_by { |address| address.primary ? 0 : 1 }, skipped: list.count(&:nil?) + [ raw.size - MAX_ADDRESSES, 0 ].max)
    rescue JSON::ParserError, EncodingError
      raise LookupError, :bad_response
    end
  end
end
