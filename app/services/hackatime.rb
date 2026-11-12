# Hackatime (Hack Club's coding-time tracker) integration. See Hackatime::Source for the seam.
module Hackatime
  # The source used when the caller names none. Switch it here once a live client exists.
  def self.source = NullSource.new
end
