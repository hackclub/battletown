class Rack::Attack
  throttle("auth/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && (req.path.start_with?("/auth/") || req.path == "/dev_login")
  end

  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless req.path.start_with?("/assets/", "/up")
  end
end
