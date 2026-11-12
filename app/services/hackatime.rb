# Hackatime (Hack Club's coding-time tracker) integration. See Hackatime::Source for the seam.
module Hackatime
  SOURCES = %w[null http].freeze

  # The source used when the caller names none, chosen by `hours_source` in config/game.yml (under `hours:`), or
  # by the HOURS_SOURCE environment variable when set: "null" (the default, reports nothing) or "http" (live
  # Hackatime, for users who linked their account: Hackatime::HttpSource). A CSV import names its own source
  # (hours:import), so "csv" is not a selectable default.
  def self.source
    name = ENV["HOURS_SOURCE"].presence || Rails.application.config_for(:game).dig(:hours, :hours_source) || "null"
    case name.to_s
    when "null" then NullSource.new
    when "http" then HttpSource.new
    else raise ArgumentError, "hours_source must be one of #{SOURCES.join(", ")}"
    end
  end
end
