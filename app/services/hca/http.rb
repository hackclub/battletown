require "net/http"
require "json"

module Hca
  # One small HTTP client for the two checkout calls. https only in production, 5 s to connect and 10 s to read, redirects are
  # never followed (a 3xx is an error), the body is cut off at MAX_BYTES, and nothing here ever logs a header, a body or a URL
  # with a token in it.
  class Http
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    MAX_BYTES = 256.kilobytes

    Response = Data.define(:status, :body)

    def initialize(base_url: Rails.configuration.x.hca.issuer, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, max_bytes: MAX_BYTES)
      @base_url = base_url.to_s.chomp("/")
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @max_bytes = max_bytes
    end

    def get(path, token:) = request(Net::HTTP::Get, path, token: token)

    def post_form(path, form) = request(Net::HTTP::Post, path, form: form)

    private

    # Raises Hca::LookupError(:unavailable) for network trouble, (:bad_response) for a redirect or an oversize body.
    def request(verb, path, token: nil, form: nil)
      uri = build_uri(path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @read_timeout
      req = verb.new(uri)
      req["Accept"] = "application/json"
      req["Authorization"] = "Bearer #{token}" if token
      req.set_form_data(form) if form

      http.request(req) do |response|
        body = +""
        response.read_body do |chunk|
          body << chunk
          raise LookupError, :bad_response if body.bytesize > @max_bytes
        end
        raise LookupError, :bad_response if (300..399).cover?(response.code.to_i)

        return Response.new(status: response.code.to_i, body: body)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, IOError
      raise LookupError, :unavailable
    end

    def build_uri(path)
      uri = URI.join("#{@base_url}/", path.to_s.delete_prefix("/"))
      raise LookupError, :bad_response if Rails.env.production? && uri.scheme != "https"
      raise LookupError, :bad_response unless %w[http https].include?(uri.scheme)

      uri
    end
  end
end
