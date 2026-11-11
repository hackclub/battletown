# TRUSTED_PROXIES: comma- or space-separated IPs and CIDRs (for example "203.0.113.0/24, 2001:db8::/32") of
# reverse proxies and load balancers that sit in front of the app and are NOT private addresses. Rails
# (request.remote_ip) and Rack::Attack (see rack_attack_client_ip.rb) walk X-Forwarded-For from the right
# and skip trusted proxies, so the first address that is not one is the client. Private and loopback
# ranges are always trusted (ActionDispatch::RemoteIp::TRUSTED_PROXIES); set this only when the proxy in
# front of the app has a public address, otherwise every visitor shares that address's throttle bucket.
#
# Invalid entries are ignored with a warning. So are catch-all ranges (/0): trusting every address would
# let clients choose their own IP through X-Forwarded-For.
module TrustedProxies
  # Yields each rejected entry with a reason; returns the valid addresses as IPAddr objects.
  def self.parse(value)
    value.to_s.split(/[,\s]+/).reject(&:empty?).filter_map do |entry|
      address = IPAddr.new(entry)
      if address.prefix.zero?
        yield entry, "matches every address" if block_given?
        next
      end
      address
    rescue IPAddr::Error
      yield entry, "not an IP address or CIDR" if block_given?
      nil
    end
  end
end

extra = TrustedProxies.parse(ENV["TRUSTED_PROXIES"]) do |entry, reason|
  Rails.logger.warn("Ignoring TRUSTED_PROXIES entry #{entry.inspect}: #{reason}")
end
# A custom list replaces the Rails defaults, so merge them in.
Rails.application.config.action_dispatch.trusted_proxies = ActionDispatch::RemoteIp::TRUSTED_PROXIES + extra if extra.any?
