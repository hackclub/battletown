require "net/http"

module SlackProfiles
  # Downloads one picture whose address came out of a Slack response. The address is data from outside, so it is never trusted:
  #
  #  - https only, on port 443, no user info, and a host that is `slack-edge.com` or `slack.com` or a subdomain of one (a fixed
  #    allowlist: an IP address, `evilslack.com`, `slack.com.evil.example` and everything else is refused before any connection);
  #  - a redirect is followed (twice at most) only when it also points at an allowlisted https host, so an open redirect cannot lead
  #    the server anywhere else;
  #  - short timeouts, and the body is read in pieces and cut off at MAX_BYTES (a declared or actual size over it is refused), so a
  #    huge or endless response is never held in memory;
  #  - the content type the server claims is never used: the bytes are identified by SlackProfiles::Avatar.
  #
  # Raises Refused with a short code ("host_not_allowed", "too_large", "download_failed"...), never a message with a URL or a body in it.
  module Download
    class Refused < StandardError; end

    ALLOWED_DOMAINS = %w[slack-edge.com slack.com].freeze
    MAX_BYTES = 1_000_000
    MAX_REDIRECTS = 2
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 5
    WRITE_TIMEOUT = 5

    module_function

    # The picture bytes (a binary String of at most MAX_BYTES).
    def call(url, redirects: MAX_REDIRECTS)
      uri = allowed_uri!(url)
      response_body = nil
      location = nil
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["Accept"] = "image/*"
        http.request(request) do |response|
          status = response.code.to_i
          if (300..399).cover?(status)
            location = response["location"].to_s
          elsif status == 200
            response_body = read_limited(response)
          else
            raise Refused, "download_failed"
          end
        end
      end
      return response_body if response_body

      raise Refused, "download_failed" unless location.present? && redirects.positive?

      call(resolve(uri, location), redirects: redirects - 1)
    rescue *Notifications::Slack::WebApiAdapter::NETWORK_ERRORS
      raise Refused, "network_error"
    end

    # The parsed address when it is an allowed Slack https address, else Refused.
    def allowed_uri!(url)
      uri = URI.parse(url.to_s)
      host = uri.host.to_s.downcase
      ok = uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? && allowed_host?(host)
      raise Refused, "host_not_allowed" unless ok

      uri
    rescue URI::InvalidURIError
      raise Refused, "host_not_allowed"
    end

    def allowed_host?(host)
      host.match?(/\A[a-z0-9.-]+\z/) && ALLOWED_DOMAINS.any? { |domain| host == domain || host.end_with?(".#{domain}") }
    end

    # A redirect target, absolute or relative to the address that sent it (checked again by `call`).
    def resolve(from, location)
      URI.join(from.to_s, location).to_s
    rescue URI::Error
      raise Refused, "host_not_allowed"
    end

    def read_limited(response)
      declared = response["content-length"].to_i
      raise Refused, "too_large" if declared > MAX_BYTES

      body = "".b
      response.read_body do |chunk|
        body << chunk.b
        raise Refused, "too_large" if body.bytesize > MAX_BYTES
      end
      body
    end
  end
end
