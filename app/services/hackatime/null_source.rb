module Hackatime
  # Reports nothing. The default until a live Hackatime client exists.
  class NullSource
    include Source

    def daily_seconds(user:, from: nil, to: nil) = []
  end
end
