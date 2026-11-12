require "socket"
require "json"
require "uri"
require "digest"
require "base64"

# A tiny in-process stand-in for hackatime.hackclub.com, served over a real local socket so the real Net::HTTP and
# OAuth code paths run (timeouts, redirects, size caps, PKCE). No network beyond 127.0.0.1.
#
#   fake = FakeHackatime.new
#   fake.on("GET", "/api/v1/authenticated/me") { |req| [ 200, { "id" => 42 } ] }
#   Rails.configuration.x.hackatime.base_url = fake.url
#   fake.requests  # everything the app sent, as Request structs
class FakeHackatime
  Request = Struct.new(:verb, :path, :query, :headers, :form, keyword_init: true)

  attr_reader :requests, :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @handlers = {}
    @requests = []
    @mutex = Mutex.new
    @running = true
    @thread = Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{port}"

  # The block gets the Request and returns [status, body_hash_or_string] or [status, body, extra_headers].
  def on(verb, path, &block)
    @handlers["#{verb} #{path}"] = block
  end

  def requests_for(verb, path) = @mutex.synchronize { @requests.select { |r| r.verb == verb && r.path == path } }

  def stop
    @running = false
    @server.close
    @thread.kill
  end

  # PKCE check used by token endpoints in tests.
  def self.pkce_matches?(verifier, challenge)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier.to_s), padding: false) == challenge
  end

  private

  def serve
    while @running
      client = @server.accept
      Thread.new(client) { |socket| handle(socket) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(socket)
    request_line = socket.gets.to_s
    verb, target, = request_line.split(" ")
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.chomp.split(": ", 2)
      headers[name.downcase] = value
    end
    body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : ""
    uri = URI.parse(target.to_s)
    request = Request.new(verb: verb, path: uri.path, query: Rack::Utils.parse_query(uri.query.to_s),
                          headers: headers, form: Rack::Utils.parse_query(body.to_s))
    @mutex.synchronize { @requests << request }

    handler = @handlers["#{verb} #{uri.path}"]
    status, payload, extra = handler ? handler.call(request) : [ 404, { "error" => "not_found" } ]
    payload = payload.is_a?(String) ? payload : payload.to_json
    head = [ "HTTP/1.1 #{status} X", "Content-Type: application/json", "Content-Length: #{payload.bytesize}", "Connection: close" ]
    (extra || {}).each { |name, value| head << "#{name}: #{value}" }
    socket.write(head.join("\r\n") + "\r\n\r\n" + payload)
  rescue Errno::EPIPE, Errno::ECONNRESET, IOError
    nil
  ensure
    socket.close unless socket.closed?
  end
end
