require "net/http"
require "json"

module Hackatime
  # Talks to the Hackatime API on behalf of one connected user (docs/HACKATIME.md). Responsibilities:
  # - refresh an expired token with the refresh token, serialised with a row lock so two requests never both refresh;
  # - mark the connection `needs_reconnect` when Hackatime rejects the credentials (and never retry blindly);
  # - map 429, 5xx, timeouts and network failures to RetryableError so a caller can try again later;
  # - never follow redirects, cap the response size, guard JSON parsing, and never log a token or a body.
  # Hackatime access tokens currently last about 16 years and come without a refresh token, so the refresh path is
  # mostly dormant, but it is here (and tested) so a change on Hackatime's side does not silently break syncing.
  class Client
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code.to_s
        super(@code)
      end
    end

    # The credentials are no longer valid: the user has to connect again.
    class AuthError < Error; end

    # Worth trying again later (rate limited, Hackatime down, network trouble).
    class RetryableError < Error; end

    # Hackatime answered, but not with something usable.
    class ResponseError < Error; end

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    MAX_RESPONSE_BYTES = 2.megabytes

    def initialize(connection, base_url: Rails.configuration.x.hackatime.base_url, client_id: Hackatime::Client.default_client_id,
                   client_secret: Hackatime::Client.default_client_secret, max_response_bytes: MAX_RESPONSE_BYTES,
                   read_timeout: READ_TIMEOUT)
      @connection = connection
      @base_url = base_url
      @client_id = client_id
      @client_secret = client_secret
      @max_response_bytes = max_response_bytes
      @read_timeout = read_timeout
    end

    def self.default_client_id
      Rails.configuration.x.hackatime.client_id || Rails.application.credentials.dig(:hackatime, :client_id)
    end

    def self.default_client_secret
      Rails.configuration.x.hackatime.client_secret || Rails.application.credentials.dig(:hackatime, :client_secret)
    end

    # GET a JSON object from the Hackatime API as the connected user. Returns the parsed Hash.
    def get_json(path, params = {})
      raise AuthError, "needs_reconnect" if @connection.needs_reconnect?

      refresh! if @connection.expired?
      sent_token = @connection.access_token
      response = request(:get, path, query: params, token: sent_token)
      if response.code == 401
        # The token was rejected. A refresh token may still rescue it; otherwise the user must reconnect.
        refresh!(rejected_token: sent_token)
        response = request(:get, path, query: params, token: @connection.access_token)
        reject_credentials!("unauthorized") if response.code == 401
      end
      parse!(response)
    end

    # Best-effort revoke at Hackatime (POST /oauth/revoke). Never raises: disconnecting must not depend on it.
    def self.revoke(token, base_url: Rails.configuration.x.hackatime.base_url)
      return if token.blank?

      client = new(HackatimeConnection.new, base_url: base_url)
      client.send(:request, :post, "/oauth/revoke", form: { token: token, client_id: client.send(:client_id), client_secret: client.send(:client_secret) })
      nil
    rescue StandardError
      nil
    end

    private

    attr_reader :client_id, :client_secret

    # Serialised with a row lock: a second caller waits, then sees the fresh token and does not refresh again.
    # The outcome is decided inside the lock but acted on after it, because raising inside would roll back the
    # `needs_reconnect` mark.
    # `rejected_token` is set after a 401: if another caller already replaced that token, there is nothing to do.
    def refresh!(rejected_token: nil)
      outcome = @connection.with_lock do
        already_fresh = rejected_token ? @connection.access_token != rejected_token : !@connection.expired?
        already_fresh ? :fresh : perform_refresh
      end
      return if outcome == :fresh || outcome == :refreshed

      reject_credentials!(outcome.to_s)
    end

    def perform_refresh
      return :no_refresh_token if @connection.refresh_token.blank?

      response = request(:post, "/oauth/token", form: {
        grant_type: "refresh_token", refresh_token: @connection.refresh_token,
        client_id: client_id, client_secret: client_secret
      })
      return :refresh_rejected if [ 400, 401 ].include?(response.code)

      body = parse!(response)
      token = body["access_token"].to_s
      return :refresh_rejected if token.blank?

      @connection.update!(
        access_token: token,
        refresh_token: body["refresh_token"].presence || @connection.refresh_token,
        expires_at: body["expires_in"].to_i.positive? ? Time.current + body["expires_in"].to_i : nil,
        scopes: body["scope"].presence || @connection.scopes,
        last_error_code: nil
      )
      :refreshed
    end

    def reject_credentials!(code)
      @connection.mark_needs_reconnect!(code) if @connection.persisted?
      raise AuthError, code
    end

    Response = Data.define(:code, :body)

    def request(verb, path, query: nil, form: nil, token: nil)
      uri = build_uri(path, query)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = @read_timeout
      req = verb == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"
      req["Authorization"] = "Bearer #{token}" if token
      req.set_form_data(form) if form

      http.request(req) do |res|
        body = +""
        res.read_body do |chunk|
          body << chunk
          raise ResponseError, "response_too_large" if body.bytesize > @max_response_bytes
        end
        return classify(Response.new(code: res.code.to_i, body: body))
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, IOError
      raise RetryableError, "network_error"
    end

    # 429 and 5xx are retryable for the caller; redirects are never followed.
    def classify(response)
      case response.code
      when 429 then raise RetryableError, "rate_limited"
      when 500..599 then raise RetryableError, "server_error"
      when 300..399 then raise ResponseError, "unexpected_redirect"
      end
      response
    end

    def parse!(response)
      raise AuthError, "forbidden" if response.code == 403
      raise ResponseError, "http_#{response.code}" unless (200..299).cover?(response.code)

      parsed = JSON.parse(response.body)
      raise ResponseError, "bad_response" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise ResponseError, "bad_response"
    end

    def build_uri(path, query)
      uri = URI.join("#{@base_url}/", path.to_s.delete_prefix("/"))
      raise ResponseError, "insecure_url" if Rails.env.production? && uri.scheme != "https"

      uri.query = URI.encode_www_form(query) if query.present?
      uri
    end
  end
end
