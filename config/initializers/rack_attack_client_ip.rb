# Rack::Attack keys its throttles on req.ip, which plain Rack computes with only the private ranges
# trusted. Behind a proxy with a public address (a CDN, a cloud load balancer) that is the proxy's address,
# so everyone would share one bucket. Use the same answer as request.remote_ip instead: it honours
# TRUSTED_PROXIES (config/initializers/trusted_proxies.rb) and is identical to Rack's when that is unset.
# A spoofed X-Forwarded-For entry on the left is never used: only addresses right of the last trusted
# proxy count. If Rails refuses the headers as a spoofing attempt, fall back to Rack's own answer.
module RackAttackClientIp
  def ip
    ActionDispatch::Request.new(env).remote_ip.presence || super
  rescue ActionDispatch::RemoteIp::IpSpoofAttackError
    super
  end
end

Rack::Attack::Request.prepend(RackAttackClientIp)
